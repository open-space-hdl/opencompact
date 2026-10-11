---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Sample-adaptive entropy coder of CCSDS 123.0-B-2 (5.4.3.2): encodes every mapped quantizer index
-- with a length-limited Golomb-power-of-2 codeword selected from adaptive per-band statistics.
-- The statistics are kept in a SECDED-protected memory.
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

    type Fsm_t is (Idle_s, Read_s, Load_s, Index_s, Code_s);

    type TwoProcess_r is record
        Fsm      : Fsm_t;
        Delta    : unsigned(D_c - 1 downto 0);
        Band     : unsigned(ZW_c - 1 downto 0);
        Init     : std_logic;
        Last     : std_logic;
        Acc      : unsigned(AccW_c - 1 downto 0);
        Cnt      : unsigned(CntW_c - 1 downto 0);
        Rhs      : unsigned(AccW_c + 1 downto 0);
        K        : natural range 0 to 31;
        CwValid  : std_logic;
        CwData   : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLength : unsigned(CwLenWidth_c - 1 downto 0);
        CwLast   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    signal RdData : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal WrEna  : std_logic;
    signal WrData : std_logic_vector(AccW_c + CntW_c - 1 downto 0);
    signal RdAddr : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);

begin

    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable Acc_v : unsigned(AccW_c - 1 downto 0);
        variable Cnt_v : unsigned(CntW_c - 1 downto 0);
        variable Rhs_v : unsigned(AccW_c + 1 downto 0);
        variable K_v   : natural range 0 to 31;
        variable U_v   : unsigned(D_c - 1 downto 0);
        variable Lsb_v : unsigned(D_c - 1 downto 0);
    begin
        v      := r;
        WrEna  <= '0';
        WrData <= (others => '0');

        if Cw_Ready = '1' then
            v.CwValid := '0';
        end if;

        In_Ready <= '0';

        case r.Fsm is

            when Idle_s =>
                if r.CwValid = '0' or Cw_Ready = '1' then
                    In_Ready <= '1';
                    if In_Valid = '1' then
                        v.Delta := resize(unsigned(In_Data), D_c);
                        v.Band  := unsigned(In_Band);
                        v.Init  := In_Init;
                        v.Last  := In_Last;
                        if In_Kind = ItemAbsLimit_c or In_Kind = ItemRelLimit_c then
                            -- Error limit values: DA or DR-bit unsigned integers (5.4.3.2.4.1)
                            v.CwValid := '1';
                            v.CwData  := std_logic_vector(resize(unsigned(In_Data), CwWidth_c));
                            v.CwLast  := In_Last;
                            if In_Kind = ItemAbsLimit_c then
                                v.CwLength := to_unsigned(AbsBitDepth_g, CwLenWidth_c);
                            else
                                v.CwLength := to_unsigned(RelBitDepth_g, CwLenWidth_c);
                            end if;
                        elsif In_First = '1' then
                            -- First mapped quantizer index of a band: uncoded (5.4.3.2.4.2)
                            v.CwValid  := '1';
                            v.CwData   := std_logic_vector(resize(unsigned(In_Data(D_c - 1 downto 0)), CwWidth_c));
                            v.CwLength := to_unsigned(D_c, CwLenWidth_c);
                            v.CwLast   := In_Last;
                        else
                            v.Fsm := Read_s;
                        end if;
                    end if;
                end if;

            -- Statistics of the band from the memory (latency two cycles)
            when Read_s =>
                v.Fsm := Load_s;

            when Load_s =>
                if r.Init = '1' then
                    -- First coded sample of the band: initial values (57), (58)
                    Acc_v := AccRom_c(to_integer(r.Band));
                    Cnt_v := shift_left(to_unsigned(1, CntW_c), InitialCountExp_g);
                else
                    Acc_v := unsigned(RdData(AccW_c - 1 downto 0));
                    Cnt_v := unsigned(RdData(AccW_c + CntW_c - 1 downto AccW_c));
                end if;
                v.Acc := Acc_v;
                v.Cnt := Cnt_v;
                v.Rhs := resize(Acc_v, Rhs_v'length) + shift_right(resize(Cnt_v * to_unsigned(49, 6), Rhs_v'length), 7);
                v.Fsm := Index_s;

            -- Code index (5.4.3.2.4.3)
            when Index_s =>
                K_v := 0;

                for k in 1 to D_c - 2 loop
                    if shift_left(resize(r.Cnt, r.Rhs'length + 32), k) <= resize(r.Rhs, r.Rhs'length + 32) then
                        K_v := k;
                    end if;
                end loop;

                v.K   := K_v;
                v.Fsm := Code_s;

            when Code_s =>
                -- Length-limited GPO2 codeword (5.4.3.2.2)
                U_v   := shift_right(r.Delta, r.K);
                Lsb_v := r.Delta and (shift_left(to_unsigned(1, D_c), r.K) - 1);
                if U_v < UnaryLimit_g then
                    v.CwData   := std_logic_vector(resize(Lsb_v, CwWidth_c) or shift_left(to_unsigned(1, CwWidth_c), r.K));
                    v.CwLength := resize(U_v, CwLenWidth_c) + 1 + r.K;
                else
                    v.CwData   := std_logic_vector(resize(r.Delta, CwWidth_c));
                    v.CwLength := to_unsigned(UnaryLimit_g + D_c, CwLenWidth_c);
                end if;
                v.CwValid := '1';
                v.CwLast  := r.Last;
                -- Statistics update (60), (61)
                Acc_v := r.Acc;
                Cnt_v := r.Cnt;
                if Cnt_v < 2 ** RescaleCounterSize_g - 1 then
                    Acc_v := Acc_v + r.Delta;
                    Cnt_v := Cnt_v + 1;
                else
                    Acc_v := shift_right(Acc_v + r.Delta + 1, 1);
                    Cnt_v := shift_right(Cnt_v + 1, 1);
                end if;
                -- Written in this cycle: the next item may read the same band
                WrEna  <= '1';
                WrData <= std_logic_vector(Cnt_v) & std_logic_vector(Acc_v);
                v.Fsm  := Idle_s;

            when others =>
                v.Fsm := Idle_s;

        end case;

        r_next <= v;
    end process;

    RdAddr    <= In_Band when r.Fsm = Idle_s else std_logic_vector(r.Band);
    Cw_Valid  <= r.CwValid;
    Cw_Data   <= r.CwData;
    Cw_Length <= std_logic_vector(r.CwLength);
    Cw_Last   <= r.CwLast;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Fsm     <= Idle_s;
                r.CwValid <= '0';
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
