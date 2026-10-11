---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Sample-adaptive entropy coder of CCSDS 123.0-B-2 (5.4.3.2): encodes every mapped quantizer index
-- with a length-limited Golomb-power-of-2 codeword selected from adaptive per-band statistics.
-- One item per clock cycle passes a pipeline without internal stalls; the statistics of a band come
-- from a SECDED-protected memory or, while the previous sample of the band is still in the
-- pipeline, directly from that sample. The output FIFO has room for every item in flight.
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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_sample_adaptive_coder is
    generic (
        ZSize_g               : positive range 1 to 65536 := 4;
        DynamicRange_g        : positive range 2 to 32    := 16;
        UnaryLimit_g          : positive range 8 to 32    := 16;
        RescaleCounterSize_g  : positive range 4 to 11    := 6;
        InitialCountExp_g     : positive range 1 to 8     := 1;
        AccuInitBandVarying_g : boolean                   := false;
        AccuInit_g            : integer_vector            := (0 => 3);
        AbsBitDepth_g         : positive range 1 to 16    := 1;
        RelBitDepth_g         : positive range 1 to 16    := 1;
        RamStyle_g            : string                    := "auto"
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
architecture rtl of ocp_sample_adaptive_coder is

    constant D_c    : positive := DynamicRange_g;
    constant AccW_c : positive := D_c + RescaleCounterSize_g + 2;
    constant CntW_c : positive := RescaleCounterSize_g + 1;
    constant ZW_c   : positive := log2ceil(ZSize_g + 1);
    constant InW_c  : positive := maximum(D_c, 16);

    -- Pipeline: 0 issue (memory read), 2 statistics and their update, 3 sum of (62), 4 code index,
    -- 5 codeword
    constant StStat_c : natural  := 2;
    constant StRhs_c  : natural  := 3;
    constant StK_c    : natural  := 4;
    constant StCw_c   : natural  := 5;
    constant NSt_c    : positive := StCw_c + 1;

    constant FifoDepth_c : positive := 16;

    -- Initial accumulator value of band z (CCSDS 5.4.3.2.3.3)
    type AccRom_t is array (0 to ZSize_g - 1) of unsigned(AccW_c - 1 downto 0);

    function accRom return AccRom_t is
        variable R_v  : AccRom_t;
        variable K_v  : natural;
        variable Kp_v : natural;
    begin

        for z in 0 to ZSize_g - 1 loop
            if AccuInitBandVarying_g then
                K_v := vecElem(AccuInit_g, z);
            else
                K_v := vecElem(AccuInit_g, 0);
            end if;
            -- (59)
            if K_v <= 30 - D_c then
                Kp_v := K_v;
            else
                Kp_v := 2 * K_v + D_c - 30;
            end if;
            -- (58) with Gamma(1) = 2^gamma0
            R_v(z) := resize(shift_right(shift_left(to_unsigned(3, AccW_c + 8), Kp_v + 6) - 49 &
                                         (InitialCountExp_g - 1 downto 0 => '0'), 7), AccW_c);
        end loop;

        return R_v;
    end function;

    constant AccRom_c : AccRom_t := accRom;

    type Item_r is record
        Valid  : std_logic;
        Kind   : std_logic_vector(1 downto 0);
        Data   : std_logic_vector(InW_c - 1 downto 0);
        Band   : unsigned(ZW_c - 1 downto 0);
        First  : std_logic;
        Init   : std_logic;
        Last   : std_logic;
        -- Statistics before and after this sample
        Acc    : unsigned(AccW_c - 1 downto 0);
        Cnt    : unsigned(CntW_c - 1 downto 0);
        AccNew : unsigned(AccW_c - 1 downto 0);
        CntNew : unsigned(CntW_c - 1 downto 0);
        Rhs    : unsigned(AccW_c + 1 downto 0);
        K      : natural range 0 to 31;
        -- Codeword
        CwData : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLen  : unsigned(CwLenWidth_c - 1 downto 0);
    end record;

    type ItemArr_t is array (0 to NSt_c - 1) of Item_r;

    type TwoProcess_r is record
        P        : ItemArr_t;
        Inflight : natural range 0 to NSt_c + 1;
    end record;

    signal r, r_next : TwoProcess_r;

    signal RdData       : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal WrEna        : std_logic;
    signal WrAddr       : std_logic_vector(ZW_c - 1 downto 0);
    signal WrData       : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal FifoInValid  : std_logic;
    signal FifoInData   : std_logic_vector(CwWidth_c - 1 downto 0);
    signal FifoInLength : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal FifoInLast   : std_logic;
    signal FifoLevel    : std_logic_vector(log2ceil(FifoDepth_c + 2) - 1 downto 0);
    signal EccSecVec    : std_logic_vector(1 downto 0);
    signal EccDedVec    : std_logic_vector(1 downto 0);

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable I_v     : Item_r;
        variable O_v     : Item_r;
        variable Acc_v   : unsigned(AccW_c - 1 downto 0);
        variable Cnt_v   : unsigned(CntW_c - 1 downto 0);
        variable Fwd_v   : boolean;
        variable K_v     : natural range 0 to 31;
        variable Dlt_v   : unsigned(D_c - 1 downto 0);
        variable U_v     : unsigned(D_c - 1 downto 0);
        variable Lsb_v   : unsigned(D_c - 1 downto 0);
        variable Coded_v : boolean;
    begin
        v := r;

        for k in 1 to NSt_c - 1 loop
            v.P(k) := r.P(k - 1);
        end loop;

        -- Issue: room in the output FIFO for every item in flight
        O_v       := r.P(0);
        O_v.Valid := '0';
        In_Ready  <= '0';
        if r.Inflight + to_integer(unsigned(FifoLevel)) + 2 <= FifoDepth_c then
            In_Ready <= '1';
            if In_Valid = '1' then
                O_v.Valid := '1';
                O_v.Kind  := In_Kind;
                O_v.Data  := In_Data;
                O_v.Band  := unsigned(In_Band);
                O_v.First := In_First;
                O_v.Init  := In_Init;
                O_v.Last  := In_Last;
            end if;
        end if;
        v.P(0) := O_v;

        -- Statistics of the band: initial values (57), (58) for the first coded sample of the band,
        -- else those left by the previous sample of the band, from the pipeline while it has not yet
        -- reached the memory; update (60), (61)
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
        O_v.Acc := Acc_v;
        O_v.Cnt := Cnt_v;
        Dlt_v   := resize(unsigned(I_v.Data), D_c);
        if Cnt_v < 2 ** RescaleCounterSize_g - 1 then
            O_v.AccNew := Acc_v + Dlt_v;
            O_v.CntNew := Cnt_v + 1;
        else
            O_v.AccNew := shift_right(Acc_v + Dlt_v + 1, 1);
            O_v.CntNew := shift_right(Cnt_v + 1, 1);
        end if;
        v.P(StStat_c) := O_v;

        -- Code index (5.4.3.2.4.3): largest k <= D - 2 with Gamma 2^k <= Sigma + floor(49 Gamma / 2^7)
        I_v              := r.P(StRhs_c - 1);
        v.P(StRhs_c).Rhs := resize(I_v.Acc, AccW_c + 2) +
                            shift_right(resize(I_v.Cnt * to_unsigned(49, 6), AccW_c + 2), 7);

        I_v := r.P(StK_c - 1);
        K_v := 0;

        for k in 1 to D_c - 2 loop
            if shift_left(resize(I_v.Cnt, I_v.Rhs'length + 32), k) <= resize(I_v.Rhs, I_v.Rhs'length + 32) then
                K_v := k;
            end if;
        end loop;

        v.P(StK_c).K := K_v;

        -- Codeword: error limit values (5.4.3.2.4.1), uncoded first sample of a band (5.4.3.2.4.2),
        -- length-limited GPO2 codeword (5.4.3.2.2)
        I_v     := r.P(StCw_c - 1);
        O_v     := v.P(StCw_c);
        Dlt_v   := resize(unsigned(I_v.Data), D_c);
        Coded_v := false;
        if I_v.Kind = ItemAbsLimit_c then
            O_v.CwData := std_logic_vector(resize(unsigned(I_v.Data), CwWidth_c));
            O_v.CwLen  := to_unsigned(AbsBitDepth_g, CwLenWidth_c);
        elsif I_v.Kind = ItemRelLimit_c then
            O_v.CwData := std_logic_vector(resize(unsigned(I_v.Data), CwWidth_c));
            O_v.CwLen  := to_unsigned(RelBitDepth_g, CwLenWidth_c);
        elsif I_v.First = '1' then
            O_v.CwData := std_logic_vector(resize(Dlt_v, CwWidth_c));
            O_v.CwLen  := to_unsigned(D_c, CwLenWidth_c);
        else
            Coded_v := true;
        end if;
        if Coded_v then
            U_v   := shift_right(Dlt_v, I_v.K);
            Lsb_v := Dlt_v and (shift_left(to_unsigned(1, D_c), I_v.K) - 1);
            if U_v < UnaryLimit_g then
                O_v.CwData := std_logic_vector(resize(Lsb_v, CwWidth_c) or shift_left(to_unsigned(1, CwWidth_c), I_v.K));
                O_v.CwLen  := resize(U_v, CwLenWidth_c) + 1 + I_v.K;
            else
                O_v.CwData := std_logic_vector(resize(Dlt_v, CwWidth_c));
                O_v.CwLen  := to_unsigned(UnaryLimit_g + D_c, CwLenWidth_c);
            end if;
        end if;
        v.P(StCw_c) := O_v;

        -- Statistics into the memory
        I_v    := r.P(StStat_c);
        WrEna  <= I_v.Valid and toSl(I_v.Kind = ItemSample_c) and not I_v.First;
        WrAddr <= std_logic_vector(I_v.Band);
        WrData <= std_logic_vector(I_v.CntNew) & std_logic_vector(I_v.AccNew);

        -- Output FIFO
        I_v          := r.P(StCw_c);
        FifoInValid  <= I_v.Valid;
        FifoInData   <= I_v.CwData;
        FifoInLength <= std_logic_vector(I_v.CwLen);
        FifoInLast   <= I_v.Last;

        if v.P(0).Valid = '1' and I_v.Valid = '0' then
            v.Inflight := r.Inflight + 1;
        elsif v.P(0).Valid = '0' and I_v.Valid = '1' then
            v.Inflight := r.Inflight - 1;
        end if;

        r_next <= v;
    end process;

    Ecc_Sec <= or(EccSecVec);
    Ecc_Ded <= or(EccDedVec);

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then

                for k in 0 to NSt_c - 1 loop
                    r.P(k).Valid <= '0';
                end loop;

                r.Inflight <= 0;
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
            Rd_Addr   => In_Band,
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
            In_Ready  => open,
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
