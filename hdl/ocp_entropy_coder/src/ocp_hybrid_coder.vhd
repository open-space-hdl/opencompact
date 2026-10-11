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
-- compressed image tail (flush words, final accumulators and a '1' bit). The per-band statistics
-- are kept in a SECDED-protected memory.
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
    constant KMax_c : positive := maximum(D_c - 2, 2);

    -- Images of a single pixel per band never update the accumulators
    constant OnePixel_c : boolean := XSize_g = 1 and YSize_g = 1;

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

    type PrefixArr_t is array (0 to 15) of unsigned(7 downto 0);

    type Fsm_t is (
        Idle_s, Read_s, Update_s, Classify_s, Code_s, Rom_s, Lookup_s, Emit_s, Flush_s, TailRead_s,
        TailWait_s, TailAcc_s, TailEnd_s
    );

    type TwoProcess_r is record
        Fsm      : Fsm_t;
        Delta    : unsigned(D_c - 1 downto 0);
        Band     : unsigned(ZW_c - 1 downto 0);
        Init     : std_logic;
        Last     : std_logic;
        Prefix   : PrefixArr_t;
        Code     : natural range 0 to 15;
        Acc      : unsigned(AccW_c - 1 downto 0);
        Cnt      : unsigned(CntW_c - 1 downto 0);
        High     : std_logic;
        K        : natural range 0 to 31;
        LeAddr   : natural range 0 to LeTrans_c'high;
        -- Pending codewords of the current sample: rescaling bit, main codeword, low-entropy output
        Pend     : std_logic_vector(0 to 2);
        PendData : std_logic_vector(CwWidth_c - 1 downto 0);
        PendLen  : unsigned(CwLenWidth_c - 1 downto 0);
        RescBit  : std_logic;
        LeData   : std_logic_vector(CwWidth_c - 1 downto 0);
        LeLen    : unsigned(CwLenWidth_c - 1 downto 0);
        TailIdx  : natural range 0 to ZSize_g;
        CwValid  : std_logic;
        CwData   : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLength : unsigned(CwLenWidth_c - 1 downto 0);
        CwLast   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    signal RdAddr : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
    signal RdData : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal WrEna  : std_logic;
    signal WrData : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal LeWord : std_logic_vector(26 downto 0);

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

begin

    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Acc_v  : unsigned(AccW_c - 1 downto 0);
        variable Cnt_v  : unsigned(CntW_c - 1 downto 0);
        variable Lhs_v  : unsigned(CmpW_c - 1 downto 0);
        variable Rhs_v  : unsigned(CmpW_c - 1 downto 0);
        variable K_v    : natural range 0 to 31;
        variable Code_v : natural range 0 to 15;
        variable Esc_v  : unsigned(D_c - 1 downto 0);
        variable Data_v : std_logic_vector(CwWidth_c - 1 downto 0);
        variable Len_v  : unsigned(CwLenWidth_c - 1 downto 0);
        variable Sym_v  : natural range 0 to 13;
        variable Free_v : boolean;
        variable Fl_v   : std_logic_vector(13 downto 0);
    begin
        v      := r;
        WrEna  <= '0';
        WrData <= (others => '0');
        RdAddr <= std_logic_vector(r.Band);

        if Cw_Ready = '1' then
            v.CwValid := '0';
        end if;
        Free_v := r.CwValid = '0' or Cw_Ready = '1';

        In_Ready <= '0';

        case r.Fsm is

            when Idle_s =>
                RdAddr <= In_Band;
                if Free_v then
                    In_Ready <= '1';
                    if In_Valid = '1' then
                        v.Delta := resize(unsigned(In_Data), D_c);
                        v.Band  := unsigned(In_Band);
                        v.Init  := In_Init;
                        v.Last  := In_Last;
                        v.Pend  := "000";
                        if In_Kind = ItemAbsLimit_c or In_Kind = ItemRelLimit_c then
                            -- Error limit values: DA or DR-bit unsigned integers (5.4.3.3.5.1.1)
                            v.CwValid := '1';
                            v.CwData  := std_logic_vector(resize(unsigned(In_Data), CwWidth_c));
                            v.CwLast  := '0';
                            if In_Kind = ItemAbsLimit_c then
                                v.CwLength := to_unsigned(AbsBitDepth_g, CwLenWidth_c);
                            else
                                v.CwLength := to_unsigned(RelBitDepth_g, CwLenWidth_c);
                            end if;
                        elsif In_First = '1' then
                            -- First mapped quantizer index of a band: uncoded (5.4.3.3.5.1.3)
                            v.CwValid  := '1';
                            v.CwData   := std_logic_vector(resize(unsigned(In_Data(D_c - 1 downto 0)), CwWidth_c));
                            v.CwLength := to_unsigned(D_c, CwLenWidth_c);
                            v.CwLast   := '0';
                            if In_Last = '1' then
                                v.Fsm  := Flush_s;
                                v.Code := 0;
                            end if;
                        else
                            v.Fsm := Read_s;
                        end if;
                    end if;
                end if;

            -- Statistics of the band from the memory (latency two cycles)
            when Read_s =>
                v.Fsm := Update_s;

            -- Statistics update (64), (65), write back
            when Update_s =>
                if r.Init = '1' then
                    Acc_v := AccRom_c(to_integer(r.Band));
                    Cnt_v := shift_left(to_unsigned(1, CntW_c), InitialCountExp_g);
                else
                    Acc_v := unsigned(RdData(AccW_c - 1 downto 0));
                    Cnt_v := unsigned(RdData(AccW_c + CntW_c - 1 downto AccW_c));
                end if;
                if Cnt_v < 2 ** RescaleCounterSize_g - 1 then
                    Acc_v := Acc_v + shift_left(resize(r.Delta, AccW_c), 2);
                    Cnt_v := Cnt_v + 1;
                else
                    -- Rescaling: the least significant bit of the accumulator is output first (5.4.3.3.5.1.2)
                    v.Pend(0) := '1';
                    v.RescBit := Acc_v(0);
                    Acc_v     := shift_right(Acc_v + shift_left(resize(r.Delta, AccW_c), 2) + 1, 1);
                    Cnt_v     := shift_right(Cnt_v + 1, 1);
                end if;
                WrEna  <= '1';
                WrData <= std_logic_vector(Cnt_v) & std_logic_vector(Acc_v);
                v.Acc  := Acc_v;
                v.Cnt  := Cnt_v;
                v.Fsm  := Classify_s;

            -- Coding method (5.4.3.3.5.1.4), code index of a high-entropy index (66) and low-entropy code
            -- (5.4.3.3.5.3.1)
            when Classify_s =>
                Lhs_v := shift_left(resize(r.Acc, CmpW_c), 14);
                Rhs_v := resize(r.Acc, CmpW_c) + shift_right(resize(r.Cnt * to_unsigned(49, 6), CmpW_c), 5);
                K_v   := 2;

                for k in 2 to KMax_c loop
                    if shift_left(resize(r.Cnt, CmpW_c), k + 2) <= Rhs_v then
                        K_v := k;
                    end if;
                end loop;

                Code_v := 0;

                for i in 1 to 15 loop
                    if Lhs_v < resize(r.Cnt * to_unsigned(LeThreshold_c(i), 19), CmpW_c) then
                        Code_v := i;
                    end if;
                end loop;

                v.High := toSl(Lhs_v >= resize(r.Cnt * to_unsigned(LeThreshold_c(0), 19), CmpW_c));
                v.K    := K_v;
                v.Code := Code_v;
                v.Fsm  := Code_s;

            when Code_s =>
                if r.High = '1' then
                    -- High-entropy: reversed GPO2 codeword (5.4.3.3.5.2)
                    reversedGpo2(r.Delta, r.K, Data_v, Len_v);
                    v.Pend(1)  := '1';
                    v.PendData := Data_v;
                    v.PendLen  := Len_v;
                    v.Fsm      := Emit_s;
                else
                    -- Input symbol (67): escape symbol X above the input symbol limit
                    if r.Delta > LeLimit_c(r.Code) then
                        Sym_v      := LeLimit_c(r.Code) + 1;
                        Esc_v      := r.Delta - LeLimit_c(r.Code) - 1;
                        reversedGpo2(Esc_v, 0, Data_v, Len_v);
                        v.Pend(1)  := '1';
                        v.PendData := Data_v;
                        v.PendLen  := Len_v;
                    else
                        Sym_v := to_integer(resize(r.Delta, 4));
                    end if;
                    v.LeAddr := LeTransBase_c(r.Code) + to_integer(r.Prefix(r.Code)) * (LeLimit_c(r.Code) + 2) + Sym_v;
                    v.Fsm    := Rom_s;
                end if;

            -- Synchronous read of the low-entropy code table
            when Rom_s =>
                v.Fsm := Lookup_s;

            -- Low-entropy code table (registered ROM read): extend the active prefix (5.4.3.3.5.3.4, .5)
            when Lookup_s =>
                if LeWord(26) = '1' then
                    v.Pend(2)        := '1';
                    v.LeData         := std_logic_vector(resize(unsigned(LeWord(20 downto 0)), CwWidth_c));
                    v.LeLen          := resize(unsigned(LeWord(25 downto 21)), CwLenWidth_c);
                    v.Prefix(r.Code) := (others => '0');
                else
                    v.Prefix(r.Code) := unsigned(LeWord(7 downto 0));
                end if;
                v.Fsm := Emit_s;

            -- Output of the pending codewords in order
            when Emit_s =>
                if Free_v then
                    if r.Pend(0) = '1' then
                        v.CwValid  := '1';
                        v.CwData   := (0 => r.RescBit,
                                       others => '0');
                        v.CwLength := to_unsigned(1, CwLenWidth_c);
                        v.CwLast   := '0';
                        v.Pend(0)  := '0';
                    elsif r.Pend(1) = '1' then
                        v.CwValid  := '1';
                        v.CwData   := r.PendData;
                        v.CwLength := r.PendLen;
                        v.CwLast   := '0';
                        v.Pend(1)  := '0';
                    elsif r.Pend(2) = '1' then
                        v.CwValid  := '1';
                        v.CwData   := r.LeData;
                        v.CwLength := r.LeLen;
                        v.CwLast   := '0';
                        v.Pend(2)  := '0';
                    end if;
                    if v.Pend = "000" then
                        -- Last pending codeword sent (or none pending)
                        if r.Last = '1' then
                            v.Code := 0;
                            v.Fsm  := Flush_s;
                        else
                            v.Fsm := Idle_s;
                        end if;
                    end if;
                end if;

            -- Compressed image tail: flush word of every low-entropy code (5.4.3.3.5.4.2)
            when Flush_s =>
                if Free_v then
                    Fl_v       := LeFlush_c(LeFlushBase_c(r.Code) + to_integer(r.Prefix(r.Code)));
                    v.CwValid  := '1';
                    v.CwData   := std_logic_vector(resize(unsigned(Fl_v(9 downto 0)), CwWidth_c));
                    v.CwLength := resize(unsigned(Fl_v(13 downto 10)), CwLenWidth_c);
                    v.CwLast   := '0';
                    if r.Code = 15 then
                        v.TailIdx := 0;
                        v.Fsm     := TailRead_s;
                    else
                        v.Code := r.Code + 1;
                    end if;
                end if;

            -- Final high-resolution accumulator of every band (5.4.3.3.5.4.3)
            when TailRead_s =>
                RdAddr <= std_logic_vector(to_unsigned(r.TailIdx, RdAddr'length));
                v.Fsm  := TailWait_s;

            when TailWait_s =>
                RdAddr <= std_logic_vector(to_unsigned(r.TailIdx, RdAddr'length));
                v.Fsm  := TailAcc_s;

            when TailAcc_s =>
                RdAddr <= std_logic_vector(to_unsigned(r.TailIdx, RdAddr'length));
                if Free_v then
                    v.CwValid := '1';
                    if OnePixel_c then
                        v.CwData := std_logic_vector(resize(AccRom_c(r.TailIdx), CwWidth_c));
                    else
                        v.CwData := std_logic_vector(resize(unsigned(RdData(AccW_c - 1 downto 0)), CwWidth_c));
                    end if;
                    v.CwLength := to_unsigned(AccW_c, CwLenWidth_c);
                    v.CwLast   := '0';
                    if r.TailIdx = ZSize_g - 1 then
                        v.Fsm := TailEnd_s;
                    else
                        v.TailIdx := r.TailIdx + 1;
                        v.Fsm     := TailRead_s;
                    end if;
                end if;

            -- Final '1' bit (5.4.3.3.5.4.4); the bit packer appends the fill bits
            when TailEnd_s =>
                if Free_v then
                    v.CwValid  := '1';
                    v.CwData   := (0 => '1',
                                   others => '0');
                    v.CwLength := to_unsigned(1, CwLenWidth_c);
                    v.CwLast   := '1';
                    v.Prefix   := (others => (others => '0'));
                    v.Fsm      := Idle_s;
                end if;

            when others =>
                v.Fsm := Idle_s;

        end case;

        r_next <= v;
    end process;

    Cw_Valid  <= r.CwValid;
    Cw_Data   <= r.CwData;
    Cw_Length <= std_logic_vector(r.CwLength);
    Cw_Last   <= r.CwLast;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            -- Low-entropy code table as synchronous ROM
            LeWord <= LeTrans_c(r.LeAddr);
            if Rst = '1' then
                r.Fsm     <= Idle_s;
                r.CwValid <= '0';
                r.Prefix  <= (others => (others => '0'));
                r.Pend    <= "000";
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
            Wr_Addr   => std_logic_vector(r.Band),
            Wr_Ena    => WrEna,
            Wr_Data   => WrData,
            Rd_Addr   => RdAddr,
            Rd_Data   => RdData,
            Rd_Valid  => open,
            Rd_EccSec => Ecc_Sec,
            Rd_EccDed => Ecc_Ded
        );

end architecture;
