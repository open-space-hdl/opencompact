---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Hybrid entropy coder of CCSDS 123.0-B-2 (5.4.3.3): high-entropy mapped quantizer indices are
-- encoded with reversed length-limited Golomb-power-of-2 codewords, low-entropy indices with one of
-- 16 variable-to-variable length codes (annex B). After the last index the coder appends the
-- compressed image tail (flush words, final accumulators and a '1' bit).
--
-- One item per clock cycle passes a pipeline without internal stalls. The per-band statistics come
-- from a SECDED-protected memory or, while the previous sample of the band is still in the
-- pipeline, directly from that sample. The state of every low-entropy code is the address of its
-- active prefix in the code table, so one table read per clock cycle advances a code; the table also
-- provides the flush word of the new prefix. The codewords of a sample (rescaling bit, main codeword,
-- completed low-entropy codeword) leave the coder as one codeword. The tail outputs two flush words
-- and then one final accumulator per clock cycle.
--
-- Documentation: hdl/ocp_entropy_coder/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;

library work;
    use work.ocp_pkg.all;
    use work.ocp_low_entropy_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_hybrid_coder is
    generic (
        XSize_g              : positive range 1 to 65536 := 8;
        YSize_g              : positive range 1 to 65536 := 8;
        ZSize_g              : positive range 1 to 65536 := 4;
        DynamicRange_g       : positive range 2 to 32    := 16;
        UnaryLimit_g         : positive range 8 to 32    := 16;
        RescaleCounterSize_g : positive range 4 to 11    := 6;
        InitialCountExp_g    : positive range 1 to 8     := 1;
        HybridAccuInit_g     : integer_vector            := (0 => 0);
        HybridAccuInitHigh_g : integer_vector            := (0 => 0);
        AbsBitDepth_g        : positive range 1 to 16    := 1;
        RelBitDepth_g        : positive range 1 to 16    := 1;
        RamStyle_g           : string                    := "auto"
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Entropy coder input sequence
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Data   : in    std_logic_vector(maximum(DynamicRange_g, 16) - 1 downto 0);
        In_Kind   : in    std_logic_vector(1 downto 0);
        In_Band   : in    std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
        In_First  : in    std_logic;
        In_Init   : in    std_logic;
        In_Last   : in    std_logic;
        -- Codewords
        Cw_Valid  : out   std_logic;
        Cw_Ready  : in    std_logic;
        Cw_Data   : out   std_logic_vector(CwWidth_c - 1 downto 0);
        Cw_Length : out   std_logic_vector(CwLenWidth_c - 1 downto 0);
        Cw_Last   : out   std_logic;
        -- Memory errors (pulses)
        Ecc_Sec   : out   std_logic;
        Ecc_Ded   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_hybrid_coder is

    constant D_c    : positive := DynamicRange_g;
    constant AccW_c : positive := 2 + D_c + RescaleCounterSize_g;
    constant CntW_c : positive := RescaleCounterSize_g + 1;
    constant CmpW_c : positive := AccW_c + 16;
    constant ZW_c   : positive := log2ceil(ZSize_g + 1);
    constant InW_c  : positive := maximum(D_c, 16);
    constant KMax_c : positive := maximum(D_c - 2, 2);

    -- Images of a single pixel per band never update the accumulators
    constant OnePixel_c : boolean := XSize_g = 1 and YSize_g = 1;

    -- Pipeline: 0 issue (memory read), 2 statistics update, 3 and 4 coding method, code index and
    -- low-entropy code, 5 main codeword and code table address, 6 low-entropy codeword, 7 codeword
    constant StStat_c : natural  := 2;
    constant StCls1_c : natural  := 3;
    constant StCls2_c : natural  := 4;
    constant StCode_c : natural  := 5;
    constant StLe_c   : natural  := 6;
    constant StComb_c : natural  := 7;
    constant NSt_c    : positive := StComb_c + 1;

    constant FifoDepth_c : positive := 16;

    type AccRom_t is array (0 to ZSize_g - 1) of unsigned(AccW_c - 1 downto 0);

    function accRom return AccRom_t is
        variable R_v : AccRom_t;
    begin

        for z in 0 to ZSize_g - 1 loop
            -- Initial value HybridAccuInitHigh_g 2^31 + HybridAccuInit_g (5.4.3.3.4.3)
            R_v(z) := resize(shift_left(to_unsigned(vecElem(HybridAccuInitHigh_g, z), AccW_c + 31), 31) +
                             to_unsigned(vecElem(HybridAccuInit_g, z), AccW_c + 31), AccW_c);
        end loop;

        return R_v;
    end function;

    constant AccRom_c : AccRom_t := accRom;

    type ProdArr_t is array (0 to 15) of unsigned(CmpW_c - 1 downto 0);
    type RowArr_t is array (0 to 15) of unsigned(11 downto 0);
    type FlushArr_t is array (0 to 15) of std_logic_vector(13 downto 0);

    -- Flush words of the null prefixes
    function nullFlush return FlushArr_t is
        variable F_v : FlushArr_t;
    begin

        for i in 0 to 15 loop
            F_v(i) := LeFlush_c(LeFlushBase_c(i));
        end loop;

        return F_v;
    end function;

    constant NullFlush_c : FlushArr_t := nullFlush;

    type Item_r is record
        Valid   : std_logic;
        Kind    : std_logic_vector(1 downto 0);
        Data    : std_logic_vector(InW_c - 1 downto 0);
        Band    : unsigned(ZW_c - 1 downto 0);
        First   : std_logic;
        Init    : std_logic;
        Last    : std_logic;
        -- Statistics after this sample, rescaling bit
        AccNew  : unsigned(AccW_c - 1 downto 0);
        CntNew  : unsigned(CntW_c - 1 downto 0);
        Resc    : std_logic;
        RescBit : std_logic;
        -- Coding method, code index, low-entropy code
        Lhs     : unsigned(CmpW_c - 1 downto 0);
        Rhs     : unsigned(CmpW_c - 1 downto 0);
        Prod    : ProdArr_t;
        Esc     : std_logic_vector(0 to 15);
        High    : std_logic;
        K       : natural range 0 to 31;
        Code    : natural range 0 to 15;
        -- Main codeword, low-entropy table access, codeword of the sample
        Low     : std_logic;
        CwData  : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLen   : unsigned(CwLenWidth_c - 1 downto 0);
        LeData  : std_logic_vector(20 downto 0);
        LeLen   : unsigned(4 downto 0);
    end record;

    type ItemArr_t is array (0 to NSt_c - 1) of Item_r;

    type Tail_t is (TIdle_s, TFlush_s, TAcc_s);

    type TwoProcess_r is record
        P        : ItemArr_t;
        Inflight : natural range 0 to NSt_c + 1;
        -- Active prefix of every low-entropy code: address in the code table, flush word
        Row      : RowArr_t;
        Flush    : FlushArr_t;
        -- Image end: no further item until the tail is out; reads of the final accumulators in flight
        Ending   : std_logic;
        Tail     : Tail_t;
        TailIdx  : natural range 0 to maximum(ZSize_g, 16);
        TailRd   : natural range 0 to ZSize_g;
        TailV    : std_logic_vector(1 to 2);
    end record;

    signal r, r_next : TwoProcess_r;

    signal RdAddr       : std_logic_vector(ZW_c - 1 downto 0);
    signal RdData       : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal WrEna        : std_logic;
    signal WrAddr       : std_logic_vector(ZW_c - 1 downto 0);
    signal WrData       : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal LeAddr       : natural range 0 to LeTrans_c'high;
    signal LeWord       : std_logic_vector(40 downto 0);
    signal FifoInValid  : std_logic;
    signal FifoInReady  : std_logic;
    signal FifoInData   : std_logic_vector(CwWidth_c - 1 downto 0);
    signal FifoInLength : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal FifoInLast   : std_logic;
    signal FifoLevel    : std_logic_vector(log2ceil(FifoDepth_c + 2) - 1 downto 0);
    signal EccSecVec    : std_logic_vector(1 downto 0);
    signal EccDedVec    : std_logic_vector(1 downto 0);

    -- Reversed length-limited GPO2 codeword of j with code index k (5.4.3.3.3.2)
    procedure reversedGpo2 (
        j    : in    unsigned;
        k    : in    natural;
        data : out   std_logic_vector(CwWidth_c - 1 downto 0);
        len  : out   unsigned(CwLenWidth_c - 1 downto 0)) is
        variable U_v   : unsigned(j'length - 1 downto 0);
        variable Lsb_v : unsigned(CwWidth_c - 1 downto 0);
        variable Un_v  : natural range 0 to 31;
    begin
        U_v := shift_right(j, k);
        if U_v < UnaryLimit_g then
            Un_v  := to_integer(U_v);
            Lsb_v := resize(j, CwWidth_c) and (shift_left(to_unsigned(1, CwWidth_c), k) - 1);
            data  := std_logic_vector(shift_left(Lsb_v, Un_v + 1) or shift_left(to_unsigned(1, CwWidth_c), Un_v));
            len   := to_unsigned(k + 1 + Un_v, CwLenWidth_c);
        else
            data := std_logic_vector(shift_left(resize(j, CwWidth_c), UnaryLimit_g));
            len  := to_unsigned(D_c + UnaryLimit_g, CwLenWidth_c);
        end if;
    end procedure;

    -- Addresses of the null prefixes
    function initRows return RowArr_t is
        variable R_v : RowArr_t;
    begin

        for i in 0 to 15 loop
            R_v(i) := to_unsigned(LeTransBase_c(i), 12);
        end loop;

        return R_v;
    end function;

    -- Address of the active prefix after a table entry of code i
    function nextRow (word : std_logic_vector(40 downto 0); i : natural) return unsigned is
    begin
        if word(26) = '1' then
            return to_unsigned(LeTransBase_c(i), 12);
        end if;
        return unsigned(word(19 downto 8));
    end function;

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable I_v     : Item_r;
        variable O_v     : Item_r;
        variable Acc_v   : unsigned(AccW_c - 1 downto 0);
        variable Cnt_v   : unsigned(CntW_c - 1 downto 0);
        variable Fwd_v   : boolean;
        variable Dlt_v   : unsigned(D_c - 1 downto 0);
        variable K_v     : natural range 0 to 31;
        variable Code_v  : natural range 0 to 15;
        variable Esc_v   : unsigned(D_c - 1 downto 0);
        variable Data_v  : std_logic_vector(CwWidth_c - 1 downto 0);
        variable Len_v   : unsigned(CwLenWidth_c - 1 downto 0);
        variable Sym_v   : natural range 0 to 13;
        variable Row_v   : unsigned(11 downto 0);
        variable Fa_v    : std_logic_vector(13 downto 0);
        variable Fb_v    : std_logic_vector(13 downto 0);
        variable TailV_v : boolean;
    begin
        v := r;

        for k in 1 to NSt_c - 1 loop
            v.P(k) := r.P(k - 1);
        end loop;

        -- Issue: room in the output FIFO for every item in flight; after the last item of an image
        -- the tail comes first
        O_v       := r.P(0);
        O_v.Valid := '0';
        In_Ready  <= '0';
        if r.Ending = '0' and r.Inflight + to_integer(unsigned(FifoLevel)) + 2 <= FifoDepth_c then
            In_Ready <= '1';
            if In_Valid = '1' then
                O_v.Valid := '1';
                O_v.Kind  := In_Kind;
                O_v.Data  := In_Data;
                O_v.Band  := unsigned(In_Band);
                O_v.First := In_First;
                O_v.Init  := In_Init;
                O_v.Last  := In_Last;
                v.Ending  := In_Last;
            end if;
        end if;
        v.P(0) := O_v;

        -- Statistics of the band (initial values for the first coded sample, else those left by the
        -- previous sample of the band, from the pipeline while it has not yet reached the memory) and
        -- their update (64), (65); with rescaling the least significant bit of the accumulator is
        -- output first (5.4.3.3.5.1.2)
        I_v   := r.P(StStat_c - 1);
        O_v   := v.P(StStat_c);
        Acc_v := unsigned(RdData(AccW_c - 1 downto 0));
        Cnt_v := unsigned(RdData(AccW_c + CntW_c - 1 downto AccW_c));
        Fwd_v := false;

        for k in StStat_c to StStat_c + 2 loop
            if not Fwd_v and r.P(k).Valid = '1' and r.P(k).Kind = ItemSample_c and r.P(k).First = '0' and
               r.P(k).Band = I_v.Band then
                Acc_v := r.P(k).AccNew;
                Cnt_v := r.P(k).CntNew;
                Fwd_v := true;
            end if;
        end loop;

        if I_v.Init = '1' then
            Acc_v := AccRom_c(to_integer(I_v.Band));
            Cnt_v := shift_left(to_unsigned(1, CntW_c), InitialCountExp_g);
        end if;
        Dlt_v       := resize(unsigned(I_v.Data), D_c);
        O_v.RescBit := Acc_v(0);
        if Cnt_v < 2 ** RescaleCounterSize_g - 1 then
            O_v.Resc   := '0';
            O_v.AccNew := Acc_v + shift_left(resize(Dlt_v, AccW_c), 2);
            O_v.CntNew := Cnt_v + 1;
        else
            O_v.Resc   := '1';
            O_v.AccNew := shift_right(Acc_v + shift_left(resize(Dlt_v, AccW_c), 2) + 1, 1);
            O_v.CntNew := shift_right(Cnt_v + 1, 1);
        end if;
        v.P(StStat_c) := O_v;

        -- Coding method (5.4.3.3.5.1.4), code index of a high-entropy index (66), low-entropy code
        -- (5.4.3.3.5.3.1): products, then comparisons
        I_v     := r.P(StCls1_c - 1);
        O_v     := v.P(StCls1_c);
        O_v.Lhs := shift_left(resize(I_v.AccNew, CmpW_c), 14);
        O_v.Rhs := resize(I_v.AccNew, CmpW_c) + shift_right(resize(I_v.CntNew * to_unsigned(49, 6), CmpW_c), 5);

        Dlt_v := resize(unsigned(I_v.Data), D_c);

        for i in 0 to 15 loop
            O_v.Prod(i) := resize(I_v.CntNew * to_unsigned(LeThreshold_c(i), 19), CmpW_c);
            -- Index above the input symbol limit of code i: escape symbol
            O_v.Esc(i) := toSl(Dlt_v > LeLimit_c(i));
        end loop;

        v.P(StCls1_c) := O_v;

        I_v := r.P(StCls2_c - 1);
        O_v := v.P(StCls2_c);
        K_v := 2;

        for k in 2 to KMax_c loop
            if shift_left(resize(I_v.CntNew, CmpW_c), k + 2) <= I_v.Rhs then
                K_v := k;
            end if;
        end loop;

        Code_v := 0;

        for i in 1 to 15 loop
            if I_v.Lhs < I_v.Prod(i) then
                Code_v := i;
            end if;
        end loop;

        O_v.High      := toSl(I_v.Lhs >= I_v.Prod(0));
        O_v.K         := K_v;
        O_v.Code      := Code_v;
        v.P(StCls2_c) := O_v;

        -- Main codeword: error limit values (5.4.3.3.5.1.1), uncoded first index of a band
        -- (5.4.3.3.5.1.3), high-entropy reversed GPO2 codeword (5.4.3.3.5.2) or escape codeword of a
        -- low-entropy index above the input symbol limit (67); input symbol into the low-entropy code
        -- (5.4.3.3.5.3.4): the address of the active prefix comes from the table entry just read when
        -- the previous sample advanced the same code
        I_v       := r.P(StCode_c - 1);
        O_v       := v.P(StCode_c);
        Dlt_v     := resize(unsigned(I_v.Data), D_c);
        O_v.Low   := '0';
        O_v.CwLen := (others => '0');
        Sym_v     := 0;
        if I_v.Kind = ItemAbsLimit_c then
            O_v.CwData := std_logic_vector(resize(unsigned(I_v.Data), CwWidth_c));
            O_v.CwLen  := to_unsigned(AbsBitDepth_g, CwLenWidth_c);
            O_v.Resc   := '0';
        elsif I_v.Kind = ItemRelLimit_c then
            O_v.CwData := std_logic_vector(resize(unsigned(I_v.Data), CwWidth_c));
            O_v.CwLen  := to_unsigned(RelBitDepth_g, CwLenWidth_c);
            O_v.Resc   := '0';
        elsif I_v.First = '1' then
            O_v.CwData := std_logic_vector(resize(Dlt_v, CwWidth_c));
            O_v.CwLen  := to_unsigned(D_c, CwLenWidth_c);
            O_v.Resc   := '0';
        elsif I_v.High = '1' then
            reversedGpo2(Dlt_v, I_v.K, Data_v, Len_v);
            O_v.CwData := Data_v;
            O_v.CwLen  := Len_v;
        else
            O_v.Low    := I_v.Valid;
            O_v.CwData := (others => '0');
            if I_v.Esc(I_v.Code) = '1' then
                Sym_v      := LeLimit_c(I_v.Code) + 1;
                Esc_v      := Dlt_v - LeLimit_c(I_v.Code) - 1;
                reversedGpo2(Esc_v, 0, Data_v, Len_v);
                O_v.CwData := Data_v;
                O_v.CwLen  := Len_v;
            else
                Sym_v := to_integer(resize(Dlt_v, 4));
            end if;
        end if;
        if r.P(StCode_c).Low = '1' and r.P(StCode_c).Code = I_v.Code then
            Row_v := nextRow(LeWord, I_v.Code);
        else
            Row_v := r.Row(I_v.Code);
        end if;
        -- Rows are aligned to a power of two above the symbols of the code
        LeAddr        <= to_integer(Row_v or to_unsigned(Sym_v, 12));
        v.P(StCode_c) := O_v;

        -- Low-entropy code table entry: completed input codeword (output codeword) or extended active
        -- prefix (5.4.3.3.5.3.4, 5.4.3.3.5.3.5); rescaling bit before the main codeword
        I_v := r.P(StLe_c - 1);
        O_v := v.P(StLe_c);
        if I_v.Low = '1' then
            v.Row(I_v.Code)   := nextRow(LeWord, I_v.Code);
            v.Flush(I_v.Code) := LeWord(40 downto 27);
        end if;
        O_v.LeLen  := (others => '0');
        O_v.LeData := LeWord(20 downto 0);
        if I_v.Low = '1' and LeWord(26) = '1' then
            O_v.LeLen := unsigned(LeWord(25 downto 21));
        end if;
        if I_v.Resc = '1' and I_v.Kind = ItemSample_c then
            O_v.CwData                        := I_v.CwData;
            O_v.CwData(to_integer(I_v.CwLen)) := I_v.RescBit;
            O_v.CwLen                         := I_v.CwLen + 1;
        end if;
        v.P(StLe_c) := O_v;

        -- Codeword of the sample: main codeword followed by the completed low-entropy codeword
        I_v                     := r.P(StComb_c - 1);
        O_v                     := v.P(StComb_c);
        O_v.CwData              := std_logic_vector(shift_left(unsigned(I_v.CwData), to_integer(I_v.LeLen)));
        O_v.CwData(20 downto 0) := O_v.CwData(20 downto 0) or
                                   (I_v.LeData and std_logic_vector(shift_left(to_unsigned(1, 21), to_integer(I_v.LeLen)) - 1));
        O_v.CwLen               := I_v.CwLen + I_v.LeLen;
        v.P(StComb_c)           := O_v;

        -- Statistics into the memory
        I_v    := r.P(StStat_c);
        WrEna  <= I_v.Valid and toSl(I_v.Kind = ItemSample_c) and not I_v.First;
        WrAddr <= std_logic_vector(I_v.Band);
        WrData <= std_logic_vector(I_v.CntNew) & std_logic_vector(I_v.AccNew);

        -- Output FIFO: codewords of the items, then the tail
        I_v          := r.P(StComb_c);
        FifoInValid  <= I_v.Valid;
        FifoInData   <= I_v.CwData;
        FifoInLength <= std_logic_vector(I_v.CwLen);
        FifoInLast   <= '0';
        RdAddr       <= In_Band;

        if v.P(0).Valid = '1' and I_v.Valid = '0' then
            v.Inflight := r.Inflight + 1;
        elsif v.P(0).Valid = '0' and I_v.Valid = '1' then
            v.Inflight := r.Inflight - 1;
        end if;

        -------------------------------------------------------------------------------------------
        -- Compressed image tail (5.4.3.3.5.4) once the last item has left the pipeline: flush words of
        -- the low-entropy codes (two per codeword), final accumulator of every band (read one per
        -- cycle, room in the codeword buffer for the reads in flight), a '1' bit after the last
        -------------------------------------------------------------------------------------------
        TailV_v := false;
        v.TailV := '0' & r.TailV(1);

        case r.Tail is
            when TIdle_s =>
                if r.Ending = '1' and r.Inflight = 0 and I_v.Valid = '0' then
                    v.Tail    := TFlush_s;
                    v.TailIdx := 0;
                end if;

            when TFlush_s =>
                Fa_v := r.Flush(2 * (r.TailIdx mod 8));
                Fb_v := r.Flush(2 * (r.TailIdx mod 8) + 1);
                if FifoInReady = '1' then
                    TailV_v      := true;
                    FifoInLength <= std_logic_vector(resize(unsigned(Fa_v(13 downto 10)), CwLenWidth_c) +
                                                     resize(unsigned(Fb_v(13 downto 10)), CwLenWidth_c));
                    FifoInData   <= std_logic_vector(shift_left(resize(unsigned(Fa_v(9 downto 0)), CwWidth_c),
                                                                to_integer(unsigned(Fb_v(13 downto 10)))) or
                                                     resize(unsigned(Fb_v(9 downto 0)), CwWidth_c));
                    if r.TailIdx = 7 then
                        v.TailRd  := 0;
                        v.TailIdx := 0;
                        v.Tail    := TAcc_s;
                    else
                        v.TailIdx := r.TailIdx + 1;
                    end if;
                end if;

            when TAcc_s =>
                -- Reads: the memory delivers the accumulator two cycles later
                RdAddr <= std_logic_vector(to_unsigned(r.TailRd mod ZSize_g, ZW_c));
                if r.TailRd < ZSize_g and to_integer(unsigned(FifoLevel)) + 4 <= FifoDepth_c then
                    v.TailV(1) := '1';
                    v.TailRd   := r.TailRd + 1;
                end if;
                if r.TailV(2) = '1' then
                    TailV_v      := true;
                    FifoInLength <= std_logic_vector(to_unsigned(AccW_c, CwLenWidth_c));
                    if OnePixel_c then
                        FifoInData <= std_logic_vector(resize(AccRom_c(r.TailIdx mod ZSize_g), CwWidth_c));
                    else
                        FifoInData <= std_logic_vector(resize(unsigned(RdData(AccW_c - 1 downto 0)), CwWidth_c));
                    end if;
                    if r.TailIdx mod ZSize_g = ZSize_g - 1 then
                        -- Final '1' bit (5.4.3.3.5.4.4); the bit packer appends the fill bits
                        FifoInLength <= std_logic_vector(to_unsigned(AccW_c + 1, CwLenWidth_c));
                        if OnePixel_c then
                            FifoInData <= std_logic_vector(shift_left(resize(AccRom_c(r.TailIdx mod ZSize_g), CwWidth_c), 1)
                                                           or to_unsigned(1, CwWidth_c));
                        else
                            FifoInData <= std_logic_vector(shift_left(resize(unsigned(RdData(AccW_c - 1 downto 0)), CwWidth_c), 1)
                                                           or to_unsigned(1, CwWidth_c));
                        end if;
                        FifoInLast <= '1';
                        v.Tail     := TIdle_s;
                        v.Ending   := '0';
                        v.Row      := initRows;
                        v.Flush    := NullFlush_c;
                    else
                        v.TailIdx := r.TailIdx + 1;
                    end if;
                end if;

            when others =>
                v.Tail := TIdle_s;

        end case;

        if TailV_v then
            FifoInValid <= '1';
        end if;

        r_next <= v;
    end process;

    Ecc_Sec <= or(EccSecVec);
    Ecc_Ded <= or(EccDedVec);

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            -- Low-entropy code table as synchronous ROM
            LeWord <= LeTrans_c(LeAddr);
            if Rst = '1' then

                for k in 0 to NSt_c - 1 loop
                    r.P(k).Valid <= '0';
                    r.P(k).Low   <= '0';
                end loop;

                r.Row      <= initRows;
                r.Flush    <= NullFlush_c;
                r.TailV    <= "00";
                r.Inflight <= 0;
                r.Ending   <= '0';
                r.Tail     <= TIdle_s;
            end if;
        end if;
    end process;

    -- Accumulator and counter of every band
    i_stats_ram : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g       => ZSize_g + 1,
            Width_g       => AccW_c + CntW_c,
            RamStyle_g    => RamStyle_g,
            EccPipeline_g => 1
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            Wr_Addr   => WrAddr,
            Wr_Ena    => WrEna,
            Wr_Data   => WrData,
            Rd_Addr   => RdAddr,
            Rd_Data   => RdData,
            Rd_Valid  => open,
            Rd_EccSec => EccSecVec(0),
            Rd_EccDed => EccDedVec(0)
        );

    i_cw_buffer : entity work.ocp_cw_buffer
        generic map (
            Depth_g    => FifoDepth_c,
            RamStyle_g => RamStyle_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => FifoInValid,
            In_Ready  => FifoInReady,
            In_Data   => FifoInData,
            In_Length => FifoInLength,
            In_Last   => FifoInLast,
            In_Level  => FifoLevel,
            Cw_Valid  => Cw_Valid,
            Cw_Ready  => Cw_Ready,
            Cw_Data   => Cw_Data,
            Cw_Length => Cw_Length,
            Cw_Last   => Cw_Last,
            Ecc_Sec   => EccSecVec(1),
            Ecc_Ded   => EccDedVec(1)
        );

end architecture;
