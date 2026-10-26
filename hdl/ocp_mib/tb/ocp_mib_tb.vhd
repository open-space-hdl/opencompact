---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_mib: register accesses through the AXI-Lite VVC of UVVM.
--
-- * test_config: the registers ID to BLOCK equal the words of tools/ocp_mib_words.json for the
--   configuration (generic ExpWords_g); unused addresses read zero; writes to read-only registers
--   and unused addresses change nothing; every access is answered with OKAY
-- * test_counters: event pulses on every input, in bursts and back to back, increment their
--   counter only; a write clears one counter; an event in the cycle of the clearing write counts
-- * test_reset: a reset clears every counter
-- * test_config also checks the registers of the runtime configuration without it: NEXT_X to
--   NEXT_LIMITS, CONTROL and STATUS read zero, writes change nothing, LIMITS reads the error limit
--   values of the generics (ExpLimits_g)
-- * test_runtime_config (RuntimeConfig_g): reset values and readback of NEXT_X to NEXT_LIMITS; a
--   valid COMMIT passes the values to the configuration outputs and sets CFG_PENDING, which
--   Cfg_Taken clears; IMAGE_X to LIMITS read the Act_ inputs; every field at 0, 1, its maximum and
--   its maximum + 1 (and NX = 1 where width 1 is not allowed): an invalid COMMIT sets CFG_ERROR and
--   leaves the outputs, a write of '1' clears CFG_ERROR
-- * test_runtime_commit: the five configuration outputs change in the same clock cycle; COMMITs
--   one clock cycle before, in and after a Cfg_Taken pulse: in the cycle of Cfg_Taken the outputs
--   carry the previous values, after the COMMIT in that cycle CFG_PENDING stays set; with
--   RuntimeParams_g the parameter outputs change in the same clock cycle as well
-- * test_runtime_params (RuntimeParams_g): reset values and readback of NEXT_SAMPLES to NEXT_BLOCK
--   (fields of options not in use read zero); every parameter in use at the bounds of its range and
--   one value beyond each, the dependent ranges against the pending values: a valid COMMIT reaches
--   the outputs, an invalid one sets CFG_ERROR and leaves them; the parameter fields of SAMPLES to
--   BLOCK read the Act_ inputs; GENERICS.RUNTIME_PARAMS and the ID of version 3
-- * test_runtime_config without the runtime parameters also checks that NEXT_SAMPLES to NEXT_BLOCK
--   read zero, ignore writes and that the Act_ inputs of the parameters change no register
--
-- Documentation: hdl/ocp_mib/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
    use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axilite;
    context bitvis_vip_axilite.vvc_context;

library vunit_lib;
    context vunit_lib.vunit_run_context;

library work;
    use work.ocp_pkg.all;
    use work.ocp_regs_pkg.all;
    use work.ocp_tb_pkg.all;
    use work.ocp_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_mib_tb is
    generic (
        runner_cfg             : string;
        -- Expected words of the registers ID to BLOCK (comma-separated decimal values)
        ExpWords_g             : string   := "";
        InStreamWidth_g        : positive := 128;
        OutStreamWidth_g       : positive := 128;
        OutWidth_g             : positive := 64;
        Speculation_g          : boolean  := true;
        XSize_g                : positive := 8;
        YSize_g                : positive := 8;
        ZSize_g                : positive := 4;
        DynamicRange_g         : positive := 16;
        SignedSamples_g        : boolean  := false;
        UserData_g             : natural  := 0;
        EncodingOrder_g        : string   := "BI";
        SubFrameDepth_g        : positive := 4;
        OutputWordSize_g       : positive := 1;
        EntropyCoder_g         : string   := "SAMPLE_ADAPTIVE";
        Fidelity_g             : string   := "LOSSLESS";
        SupTableCount_g        : natural  := 0;
        PredictionBands_g      : natural  := 3;
        PredictionMode_g       : string   := "FULL";
        LocalSum_g             : string   := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive := 64;
        SampleRepResolution_g  : natural  := 0;
        PeriodicUpdate_g       : boolean  := false;
        UpdatePeriodExp_g      : natural  := 0;
        WeightResolution_g     : positive := 13;
        WeightUpdateInterval_g : positive := 6;
        WeightUpdateVmin_g     : integer  := -1;
        WeightUpdateVmax_g     : integer  := 3;
        WeightExpOffsetsUsed_g : boolean  := false;
        CustomWeights_g        : boolean  := false;
        WeightInitResolution_g : natural  := 0;
        UnaryLimit_g           : positive := 16;
        RescaleCounterSize_g   : positive := 6;
        InitialCountExp_g      : positive := 1;
        AccuInitBandVarying_g  : boolean  := false;
        AccuInit_g             : string   := "3";
        BlockSize_g            : positive := 16;
        RestrictedCodes_g      : boolean  := false;
        RefInterval_g          : positive := 4096;
        AbsBandDependent_g     : boolean  := false;
        AbsBitDepth_g          : positive := 1;
        AbsErrorLimits_g       : string   := "0";
        RelBandDependent_g     : boolean  := false;
        RelBitDepth_g          : positive := 1;
        RelErrorLimits_g       : string   := "0";
        RuntimeConfig_g        : boolean  := false;
        RuntimeParams_g        : boolean  := false;
        HybridAccuInit_g       : string   := "0";
        HybridAccuInitHigh_g   : string   := "0";
        -- Expected LIMITS register (the error limit values of the generics)
        ExpLimits_g            : integer  := 0
    );
end entity;

architecture sim of ocp_mib_tb is

    constant ClkPeriod_c : time    := 10 ns;
    constant Axi_c       : natural := 0;

    -- Counter registers in the order of the event inputs
    constant NumCnt_c : positive := 6;

    type CntAddr_t is array (0 to NumCnt_c - 1) of natural;

    constant CntAddr_c : CntAddr_t := (RegImagesDone_c, RegImagesAborted_c, RegSduErrors_c, RegSdusDiscarded_c,
                                       RegEccCorrected_c, RegEccUncorrectable_c);

    signal Clk     : std_logic                           := '0';
    signal Rst     : std_logic                           := '1';
    signal Ev      : std_logic_vector(0 to NumCnt_c - 1) := (others => '0');
    signal ArAddr  : std_logic_vector(7 downto 0);
    signal ArValid : std_logic;
    signal ArReady : std_logic;
    signal AwAddr  : std_logic_vector(7 downto 0);
    signal AwValid : std_logic;
    signal AwReady : std_logic;
    signal WData   : std_logic_vector(31 downto 0);
    signal WStrb   : std_logic_vector(3 downto 0);
    signal WValid  : std_logic;
    signal WReady  : std_logic;
    signal BResp   : std_logic_vector(1 downto 0);
    signal BValid  : std_logic;
    signal BReady  : std_logic;
    signal RData   : std_logic_vector(31 downto 0);
    signal RResp   : std_logic_vector(1 downto 0);
    signal RValid  : std_logic;
    signal RReady  : std_logic;

    -- Event pulse generator: Count pulses on input Sel with Gap idle cycles between them
    signal PulseSel   : natural := 0;
    signal PulseCount : natural := 0;
    signal PulseGap   : natural := 0;
    signal PulseStart : boolean := false;
    signal PulseDone  : boolean := true;

    -- Pulses of input MonSel from the cycle in which BValid rises (the write cycle of the slave) on
    signal MonSel   : natural := 0;
    signal MonCount : natural := 0;

    -- Runtime configuration: outputs of the MIB, the take pulse and the values of the core (driven by
    -- the testbench in place of the core)
    signal Cfg_XSize    : std_logic_vector(16 downto 0);
    signal Cfg_YSize    : std_logic_vector(16 downto 0);
    signal Cfg_ZSize    : std_logic_vector(16 downto 0);
    signal Cfg_AbsLimit : std_logic_vector(15 downto 0);
    signal Cfg_RelLimit : std_logic_vector(15 downto 0);
    signal Cfg_Taken    : std_logic;
    -- Cfg_Taken pulses of the test sequencer and of the timed pulse of test_runtime_commit
    signal TakeSeq      : std_logic                     := '0';
    signal TakeTimed    : std_logic                     := '0';
    signal Act_XSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Act_YSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Act_ZSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Act_AbsLimit : std_logic_vector(15 downto 0) := (others => '0');
    signal Act_RelLimit : std_logic_vector(15 downto 0) := (others => '0');

    -- Runtime parameters: outputs of the MIB, the values of the core (driven by the testbench)
    signal Cfg_UserData       : std_logic_vector(7 downto 0);
    signal Cfg_M              : std_logic_vector(16 downto 0);
    signal Cfg_WeightInterval : std_logic_vector(3 downto 0);
    signal Cfg_WeightVmin     : std_logic_vector(4 downto 0);
    signal Cfg_WeightVmax     : std_logic_vector(4 downto 0);
    signal Cfg_UnaryLimit     : std_logic_vector(5 downto 0);
    signal Cfg_InitCountExp   : std_logic_vector(3 downto 0);
    signal Cfg_RescaleSize    : std_logic_vector(3 downto 0);
    signal Cfg_AccuInit       : std_logic_vector(3 downto 0);
    signal Cfg_RefInterval    : std_logic_vector(12 downto 0);
    signal Act_UserData       : std_logic_vector(7 downto 0)  := (others => '0');
    signal Act_M              : std_logic_vector(16 downto 0) := (others => '0');
    signal Act_WeightInterval : std_logic_vector(3 downto 0)  := (others => '0');
    signal Act_WeightVmin     : std_logic_vector(4 downto 0)  := (others => '0');
    signal Act_WeightVmax     : std_logic_vector(4 downto 0)  := (others => '0');
    signal Act_UnaryLimit     : std_logic_vector(5 downto 0)  := (others => '0');
    signal Act_InitCountExp   : std_logic_vector(3 downto 0)  := (others => '0');
    signal Act_RescaleSize    : std_logic_vector(3 downto 0)  := (others => '0');
    signal Act_AccuInit       : std_logic_vector(3 downto 0)  := (others => '0');
    signal Act_RefInterval    : std_logic_vector(12 downto 0) := (others => '0');

    -- Runtime parameters in use (CO-RP-01)
    constant Coder_c  : natural := entropyCoderCode(EntropyCoder_g);
    constant UseM_c   : boolean := EncodingOrder_g = "BI";
    constant UseAdp_c : boolean := Coder_c /= CoderBlock_c;
    constant UseK_c   : boolean := Coder_c = CoderSample_c and not AccuInitBandVarying_g;
    constant UseR_c   : boolean := Coder_c = CoderBlock_c;

    -- All configuration outputs as one vector: X, Y, Z, absolute and relative limit (bits 152 to 70), then the
    -- runtime parameters (bits 69 to 0)
    signal CfgAll : std_logic_vector(152 downto 0);

    type FieldArr_t is array (natural range <>) of integer_vector(0 to 2);

    -- Fields of CfgAll: highest bit, lowest bit, in use
    constant Fields_c : FieldArr_t(0 to 14) := (
        (152, 136, 1), (135, 119, 1), (118, 102, 1), (101, 86, 1), (85, 70, 1),
        (69, 62, toInt(RuntimeParams_g)), (61, 45, toInt(RuntimeParams_g and UseM_c)),
        (44, 41, toInt(RuntimeParams_g)), (40, 36, toInt(RuntimeParams_g)), (35, 31, toInt(RuntimeParams_g)),
        (30, 25, toInt(RuntimeParams_g and UseAdp_c)), (24, 21, toInt(RuntimeParams_g and UseAdp_c)),
        (20, 17, toInt(RuntimeParams_g and UseAdp_c)), (16, 13, toInt(RuntimeParams_g and UseK_c)),
        (12, 0, toInt(RuntimeParams_g and UseR_c)));

    -- Number of fields in use and of fields in use that are equal in a and b
    function fieldsInUse return natural is
        variable N_v : natural := 0;
    begin

        for i in Fields_c'range loop
            N_v := N_v + Fields_c(i)(2);
        end loop;

        return N_v;
    end function;

    function sameFields (a : std_logic_vector(152 downto 0); b : std_logic_vector(152 downto 0)) return natural is
        variable N_v : natural := 0;
    begin

        for i in Fields_c'range loop
            if Fields_c(i)(2) = 1 and a(Fields_c(i)(0) downto Fields_c(i)(1)) = b(Fields_c(i)(0) downto Fields_c(i)(1)) then
                N_v := N_v + 1;
            end if;
        end loop;

        return N_v;
    end function;

    -- Cfg_Taken pulse TakeOfs cycles after the write cycle of the next write (TakeArm; negative: before
    -- it, with the write cycle measured as WrDelay cycles after AwValid rises); the outputs in the cycle
    -- of the pulse
    signal TakeArm  : boolean := false;
    signal TakeOfs  : integer := 0;
    signal WrDelay  : natural := 0;
    signal TakeCnt  : natural := 0;
    signal TakeSeen : std_logic_vector(152 downto 0);

    -- Atomicity (while AtomicOn, every COMMIT changes every field): number of clock cycles in which only some of
    -- the configuration outputs changed
    signal AtomicOn : boolean := false;
    signal Partial  : natural := 0;

    -- The five configuration outputs as one vector (X, Y, Z, absolute and relative limit)
    function cfgVec (
        x : std_logic_vector;
        y : std_logic_vector;
        z : std_logic_vector;
        a : std_logic_vector;
        r : std_logic_vector) return std_logic_vector is
    begin
        return x & y & z & a & r;
    end function;

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

    Cfg_Taken <= TakeSeq or TakeTimed;

    CfgAll <= cfgVec(Cfg_XSize, Cfg_YSize, Cfg_ZSize, Cfg_AbsLimit, Cfg_RelLimit) & Cfg_UserData & Cfg_M &
              Cfg_WeightInterval & Cfg_WeightVmin & Cfg_WeightVmax & Cfg_UnaryLimit & Cfg_InitCountExp &
              Cfg_RescaleSize & Cfg_AccuInit & Cfg_RefInterval;

    Clk <= not Clk after ClkPeriod_c / 2;

    i_dut : entity work.ocp_mib
        generic map (
            InStreamWidth_g        => InStreamWidth_g,
            OutStreamWidth_g       => OutStreamWidth_g,
            OutWidth_g             => OutWidth_g,
            Speculation_g          => Speculation_g,
            XSize_g                => XSize_g,
            YSize_g                => YSize_g,
            ZSize_g                => ZSize_g,
            DynamicRange_g         => DynamicRange_g,
            SignedSamples_g        => SignedSamples_g,
            UserData_g             => UserData_g,
            EncodingOrder_g        => EncodingOrder_g,
            SubFrameDepth_g        => SubFrameDepth_g,
            OutputWordSize_g       => OutputWordSize_g,
            EntropyCoder_g         => EntropyCoder_g,
            Fidelity_g             => Fidelity_g,
            SupTableCount_g        => SupTableCount_g,
            PredictionBands_g      => PredictionBands_g,
            PredictionMode_g       => PredictionMode_g,
            LocalSum_g             => LocalSum_g,
            RegisterSize_g         => RegisterSize_g,
            SampleRepResolution_g  => SampleRepResolution_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            WeightResolution_g     => WeightResolution_g,
            WeightUpdateInterval_g => WeightUpdateInterval_g,
            WeightUpdateVmin_g     => WeightUpdateVmin_g,
            WeightUpdateVmax_g     => WeightUpdateVmax_g,
            WeightExpOffsetsUsed_g => WeightExpOffsetsUsed_g,
            CustomWeights_g        => CustomWeights_g,
            WeightInitResolution_g => WeightInitResolution_g,
            UnaryLimit_g           => UnaryLimit_g,
            RescaleCounterSize_g   => RescaleCounterSize_g,
            InitialCountExp_g      => InitialCountExp_g,
            AccuInitBandVarying_g  => AccuInitBandVarying_g,
            AccuInit_g             => parseIntVec(AccuInit_g),
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsBitDepth_g          => AbsBitDepth_g,
            AbsErrorLimits_g       => parseIntVec(AbsErrorLimits_g),
            RelBandDependent_g     => RelBandDependent_g,
            RelBitDepth_g          => RelBitDepth_g,
            RelErrorLimits_g       => parseIntVec(RelErrorLimits_g),
            HybridAccuInit_g       => parseIntVec(HybridAccuInit_g),
            HybridAccuInitHigh_g   => parseIntVec(HybridAccuInitHigh_g),
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g
        )
        port map (
            Clk                => Clk,
            Rst                => Rst,
            S_AxiLite_ArAddr   => ArAddr,
            S_AxiLite_ArValid  => ArValid,
            S_AxiLite_ArReady  => ArReady,
            S_AxiLite_AwAddr   => AwAddr,
            S_AxiLite_AwValid  => AwValid,
            S_AxiLite_AwReady  => AwReady,
            S_AxiLite_WData    => WData,
            S_AxiLite_WStrb    => WStrb,
            S_AxiLite_WValid   => WValid,
            S_AxiLite_WReady   => WReady,
            S_AxiLite_BResp    => BResp,
            S_AxiLite_BValid   => BValid,
            S_AxiLite_BReady   => BReady,
            S_AxiLite_RData    => RData,
            S_AxiLite_RResp    => RResp,
            S_AxiLite_RValid   => RValid,
            S_AxiLite_RReady   => RReady,
            Ev_ImageDone       => Ev(0),
            Ev_ImageAborted    => Ev(1),
            Ev_SduError        => Ev(2),
            Ev_SduDiscarded    => Ev(3),
            Ecc_Sec            => Ev(4),
            Ecc_Ded            => Ev(5),
            Cfg_XSize          => Cfg_XSize,
            Cfg_YSize          => Cfg_YSize,
            Cfg_ZSize          => Cfg_ZSize,
            Cfg_AbsLimit       => Cfg_AbsLimit,
            Cfg_RelLimit       => Cfg_RelLimit,
            Cfg_Taken          => Cfg_Taken,
            Act_XSize          => Act_XSize,
            Act_YSize          => Act_YSize,
            Act_ZSize          => Act_ZSize,
            Act_AbsLimit       => Act_AbsLimit,
            Act_RelLimit       => Act_RelLimit,
            Cfg_UserData       => Cfg_UserData,
            Cfg_M              => Cfg_M,
            Cfg_WeightInterval => Cfg_WeightInterval,
            Cfg_WeightVmin     => Cfg_WeightVmin,
            Cfg_WeightVmax     => Cfg_WeightVmax,
            Cfg_UnaryLimit     => Cfg_UnaryLimit,
            Cfg_InitCountExp   => Cfg_InitCountExp,
            Cfg_RescaleSize    => Cfg_RescaleSize,
            Cfg_AccuInit       => Cfg_AccuInit,
            Cfg_RefInterval    => Cfg_RefInterval,
            Act_UserData       => Act_UserData,
            Act_M              => Act_M,
            Act_WeightInterval => Act_WeightInterval,
            Act_WeightVmin     => Act_WeightVmin,
            Act_WeightVmax     => Act_WeightVmax,
            Act_UnaryLimit     => Act_UnaryLimit,
            Act_InitCountExp   => Act_InitCountExp,
            Act_RescaleSize    => Act_RescaleSize,
            Act_AccuInit       => Act_AccuInit,
            Act_RefInterval    => Act_RefInterval
        );

    i_axi : entity work.ocp_tb_axilite_master
        generic map (
            InstanceIdx_g => Axi_c,
            AddrWidth_g   => AxiAddrBits_c
        )
        port map (
            Clk     => Clk,
            ArAddr  => ArAddr,
            ArValid => ArValid,
            ArReady => ArReady,
            AwAddr  => AwAddr,
            AwValid => AwValid,
            AwReady => AwReady,
            WData   => WData,
            WStrb   => WStrb,
            WValid  => WValid,
            WReady  => WReady,
            BResp   => BResp,
            BValid  => BValid,
            BReady  => BReady,
            RData   => RData,
            RResp   => RResp,
            RValid  => RValid,
            RReady  => RReady
        );

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
        variable Words_v : integer_vector(0 to 11);
        variable D_v     : std_logic_vector(31 downto 0);
        variable Exp_v   : integer_vector(0 to NumCnt_c - 1);

        procedure syncClk is
        begin
            wait until rising_edge(Clk);
        end procedure;

        procedure chk (addr : natural; data : std_logic_vector(31 downto 0); msg : string) is
        begin
            regCheck(AXILITE_VVCT, Axi_c, addr, data, msg);
        end procedure;

        procedure wr (addr : natural; data : std_logic_vector(31 downto 0)) is
        begin
            regWrite(AXILITE_VVCT, Axi_c, addr, data);
        end procedure;

        -- Write with byte enables (a disabled byte lane is not written)
        procedure wrStrb (addr : natural; data : std_logic_vector(31 downto 0); strb : std_logic_vector(3 downto 0)) is
        begin
            axilite_write(AXILITE_VVCT, Axi_c, to_unsigned(addr, AxiAddrBits_c), data, strb,
                          "write 0x" & to_hstring(to_unsigned(addr, AxiAddrBits_c)) & " with byte enables " &
                          to_string(strb));
            await_completion(AXILITE_VVCT, Axi_c, 100 us);
        end procedure;

        -- Count pulses on input sel, gap idle cycles between two pulses
        procedure pulses (sel : natural; count : natural; gap : natural) is
        begin
            PulseSel   <= sel;
            PulseCount <= count;
            PulseGap   <= gap;
            PulseStart <= true;
            syncClk;
            PulseStart <= false;
            wait until PulseDone;
        end procedure;

        procedure chkCounters (msg : string) is
        begin

            for i in 0 to NumCnt_c - 1 loop
                chk(CntAddr_c(i), std_logic_vector(to_unsigned(Exp_v(i), 32)), msg & ": counter " & to_string(i));
            end loop;

        end procedure;

        procedure reset is
        begin
            Rst <= '1';
            wait for 5 * ClkPeriod_c;
            syncClk;
            Rst <= '0';
            syncClk;
        end procedure;

        impure function word (i : natural) return std_logic_vector is
        begin
            return std_logic_vector(to_signed(Words_v(i), 32));
        end function;

        -- Runtime configuration: limits and fields
        constant Fid_c    : natural := fidelityCode(Fidelity_g);
        constant UseAbs_c : boolean := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
        constant UseRel_c : boolean := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
        constant Wide_c   : boolean := fullPrediction(PredictionMode_g) or
                                       localSumCode(LocalSum_g) = SumWideNeighbor_c or
                                       localSumCode(LocalSum_g) = SumNarrowNeighbor_c;
        constant AbsMax_c : natural := 2 ** AbsBitDepth_g - 1;
        constant RelMax_c : natural := 2 ** RelBitDepth_g - 1;

        function w32 (v : natural) return std_logic_vector is
        begin
            return std_logic_vector(to_unsigned(v, 32));
        end function;

        function limits (a : natural; r : natural) return std_logic_vector is
        begin
            return std_logic_vector(to_unsigned(r, 16)) & std_logic_vector(to_unsigned(a, 16));
        end function;

        -- Valid runtime parameters of the COMMIT x of the commit test (x = 2, 3, 4 and NZ = x): every field
        -- differs from the reset values of the configurations of the test and from the parameters of x - 1
        function parCommit (x : natural) return integer_vector is
        begin
            return (x, 1 + x mod 2, 6 + x, x - 6, x, 8 + x, 2 + x mod 2, 5 + x, x, x);
        end function;

        -- Runtime parameters (order of the lists: user-defined data, M, log2 t_inc, vmin, vmax, Umax,
        -- gamma0, gamma*, K, r): the pending registers, their masks of the fields in use, the read-only
        -- registers of the same layout
        type RegArr_t is array (0 to 4) of natural;

        constant NextReg_c : RegArr_t := (RegNextSamples_c, RegNextOrder_c, RegNextWeights_c, RegNextAdaptive_c,
                                          RegNextBlock_c);
        constant RoReg_c   : RegArr_t := (RegSamples_c, RegOrder_c, RegWeights_c, RegAdaptive_c, RegBlock_c);

        function parMask (i : natural) return std_logic_vector is
            variable M_v : std_logic_vector(31 downto 0) := (others => '0');
        begin

            case i is
                when 0 => M_v := x"0000FF00";
                when 1 =>
                    if UseM_c then
                        M_v := x"01FFFF00";
                    end if;
                when 2 => M_v := x"003FFF00";
                when 3 =>
                    if UseAdp_c then
                        M_v := x"0000FF3F";
                    end if;
                    if UseK_c then
                        M_v := M_v or x"000F0000";
                    end if;
                when others =>
                    if UseR_c then
                        M_v := x"001FFF00";
                    end if;
            end case;

            return M_v;
        end function;

        -- Word of pending register i for the parameter values p (all fields, before the mask)
        function parWord (i : natural; p : integer_vector(0 to 9)) return std_logic_vector is
            variable W_v : std_logic_vector(31 downto 0) := (others => '0');
        begin

            case i is
                when 0 => W_v(15 downto 8) := std_logic_vector(to_unsigned(p(0), 8));
                when 1 => W_v(24 downto 8) := std_logic_vector(to_unsigned(p(1), 17));
                when 2 =>
                    W_v(21 downto 17) := std_logic_vector(to_signed(p(4), 5));
                    W_v(16 downto 12) := std_logic_vector(to_signed(p(3), 5));
                    W_v(11 downto 8)  := std_logic_vector(to_unsigned(p(2), 4));
                when 3 =>
                    W_v(19 downto 16) := std_logic_vector(to_unsigned(p(8), 4));
                    W_v(15 downto 12) := std_logic_vector(to_unsigned(p(6), 4));
                    W_v(11 downto 8)  := std_logic_vector(to_unsigned(p(7), 4));
                    W_v(5 downto 0)   := std_logic_vector(to_unsigned(p(5), 6));
                when others => W_v(20 downto 8) := std_logic_vector(to_unsigned(p(9), 13));
            end case;

            return W_v;
        end function;

        procedure setPar (p : integer_vector(0 to 9)) is
        begin

            for i in 0 to 4 loop
                wr(NextReg_c(i), parWord(i, p));
            end loop;

        end procedure;

        -- The parameter outputs equal p in the fields in use, zero otherwise
        procedure chkParOut (p : integer_vector(0 to 9); msg : string) is
            variable Q_v : integer_vector(0 to 9) := p;
        begin
            if not UseM_c then
                Q_v(1) := 0;
            end if;
            if not UseAdp_c then
                Q_v(5 to 7) := (0,
                                0,
                                0);
            end if;
            if not UseK_c then
                Q_v(8) := 0;
            end if;
            if not UseR_c then
                Q_v(9) := 0;
            end if;
            await_completion(AXILITE_VVCT, Axi_c, 10 us, "parameter outputs");
            syncClk;
            check_value(to_integer(unsigned(Cfg_UserData)), Q_v(0), ERROR, msg & ": Cfg_UserData");
            check_value(to_integer(unsigned(Cfg_M)), Q_v(1), ERROR, msg & ": Cfg_M");
            check_value(to_integer(unsigned(Cfg_WeightInterval)), Q_v(2), ERROR, msg & ": Cfg_WeightInterval");
            check_value(to_integer(signed(Cfg_WeightVmin)), Q_v(3), ERROR, msg & ": Cfg_WeightVmin");
            check_value(to_integer(signed(Cfg_WeightVmax)), Q_v(4), ERROR, msg & ": Cfg_WeightVmax");
            check_value(to_integer(unsigned(Cfg_UnaryLimit)), Q_v(5), ERROR, msg & ": Cfg_UnaryLimit");
            check_value(to_integer(unsigned(Cfg_InitCountExp)), Q_v(6), ERROR, msg & ": Cfg_InitCountExp");
            check_value(to_integer(unsigned(Cfg_RescaleSize)), Q_v(7), ERROR, msg & ": Cfg_RescaleSize");
            check_value(to_integer(unsigned(Cfg_AccuInit)), Q_v(8), ERROR, msg & ": Cfg_AccuInit");
            check_value(to_integer(unsigned(Cfg_RefInterval)), Q_v(9), ERROR, msg & ": Cfg_RefInterval");
        end procedure;

        -- Pending values and COMMIT; the configuration outputs afterwards
        procedure setNext (x : natural; y : natural; z : natural; a : natural; r : natural) is
        begin
            wr(RegNextX_c, w32(x));
            wr(RegNextY_c, w32(y));
            wr(RegNextZ_c, w32(z));
            wr(RegNextLimits_c, limits(a, r));
        end procedure;

        procedure commit is
        begin
            wr(RegControl_c, x"00000001");
        end procedure;

        procedure chkOutputs (x : natural; y : natural; z : natural; a : natural; r : natural; msg : string) is
        begin
            await_completion(AXILITE_VVCT, Axi_c, 10 us, "outputs");
            syncClk;
            check_value(to_integer(unsigned(Cfg_XSize)), x, ERROR, msg & ": Cfg_XSize");
            check_value(to_integer(unsigned(Cfg_YSize)), y, ERROR, msg & ": Cfg_YSize");
            check_value(to_integer(unsigned(Cfg_ZSize)), z, ERROR, msg & ": Cfg_ZSize");
            check_value(to_integer(unsigned(Cfg_AbsLimit)), a, ERROR, msg & ": Cfg_AbsLimit");
            check_value(to_integer(unsigned(Cfg_RelLimit)), r, ERROR, msg & ": Cfg_RelLimit");
        end procedure;

        -- STATUS: CFG_ERROR (bit 1), CFG_PENDING (bit 0)
        procedure chkStatus (err : std_logic; pend : std_logic; msg : string) is
        begin
            chk(RegStatus_c, (31 downto 2 => '0') & err & pend, msg & ": STATUS");
        end procedure;

        -- Cfg_Taken pulse (the core takes the configuration outputs)
        procedure take is
        begin
            await_completion(AXILITE_VVCT, Axi_c, 10 us, "take");
            TakeSeq <= '1';
            syncClk;
            TakeSeq <= '0';
        end procedure;

        -- One invalid COMMIT: CFG_ERROR, outputs unchanged, then cleared
        procedure invalid (x : natural; y : natural; z : natural; a : natural; r : natural; msg : string) is
        begin
            setNext(x, y, z, a, r);
            commit;
            chkStatus('1', '0', msg & " (invalid)");
            chkOutputs(XSize_g, YSize_g, ZSize_g, 1, 1, msg & " (invalid)");
            wr(RegStatus_c, x"00000002");
            chkStatus('0', '0', msg & " (cleared)");
        end procedure;

        -- A COMMIT whose write cycle is ofs clock cycles before (negative) or after a Cfg_Taken pulse; with the
        -- runtime parameters every parameter in use changes as well (parCommit)
        procedure commitAt (ofs : integer; x : natural; msg : string) is
            variable Cnt_v : natural;
        begin
            setNext(x, x, x, x mod 2, x mod 2);
            if RuntimeParams_g then
                setPar(parCommit(x));
            end if;
            await_completion(AXILITE_VVCT, Axi_c, 10 us, "pending values");
            Cnt_v   := TakeCnt;
            TakeOfs <= -ofs;
            TakeArm <= true;
            syncClk;
            TakeArm <= false;
            commit;
            await_completion(AXILITE_VVCT, Axi_c, 10 us, msg);

            while TakeCnt = Cnt_v loop
                syncClk;
            end loop;

            syncClk;
        end procedure;

        variable ParLast_v : integer_vector(0 to 9);

        -- A COMMIT of the parameters p with the pending dimensions: valid, the outputs carry p; invalid,
        -- CFG_ERROR and the previous outputs (MB-RP-02)
        procedure tryPar (p : integer_vector(0 to 9); valid : boolean; msg : string) is
        begin
            setPar(p);
            commit;
            if valid then
                chkStatus('0', '1', msg);
                chkParOut(p, msg);
                ParLast_v := p;
                take;
            else
                chkStatus('1', '0', msg & " (invalid)");
                chkParOut(ParLast_v, msg & " (invalid)");
                wr(RegStatus_c, x"00000002");
            end if;
        end procedure;

        -- Parameter values with element i replaced
        function withPar (p : integer_vector(0 to 9); i : natural; v : integer) return integer_vector is
            variable Q_v : integer_vector(0 to 9) := p;
        begin
            Q_v(i) := v;
            return Q_v;
        end function;

        constant G0Max_c : natural := minimum(8, RescaleCounterSize_g - 1);
        constant KMax_c  : natural := minimum(DynamicRange_g - 2, 14);

        -- Lower bound of gamma0 (with the hybrid coder from the initial accumulators)
        function g0Min return positive is
        begin
            if Coder_c = CoderHybrid_c then
                return hybridG0Min(DynamicRange_g, ZSize_g, parseIntVec(HybridAccuInit_g),
                                   parseIntVec(HybridAccuInitHigh_g));
            end if;
            return 1;
        end function;

        constant G0Min_c : positive := g0Min;

        variable Par_v    : integer_vector(0 to 9);
        variable Base_v   : integer_vector(0 to 9);
        variable Word32_v : std_logic_vector(31 downto 0);

        variable Prev_v : std_logic_vector(152 downto 0);
        variable Sfd_v  : natural;
        variable Cnt_v  : natural;
        variable Lim_v  : std_logic_vector(31 downto 0);
        variable LimA_v : natural;
        variable LimR_v : natural;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        await_uvvm_initialization(VOID);
        disable_log_msg(ALL_MESSAGES);
        enable_log_msg(ID_LOG_HDR);
        shared_axilite_vvc_config(Axi_c).bfm_config.max_wait_cycles := 1000;
        reset;

        while test_suite loop
            if run("test_config") then
                Words_v := parseIntVec(ExpWords_g);

                -- ID to BLOCK: the words of tools/ocp_mib_words.json
                for i in 0 to 11 loop
                    chk(4 * i, word(i), "register at 0x" & to_hstring(to_unsigned(4 * i, 8)));
                end loop;

                check_value(word(0), RegMapId_c, ERROR, "ID of the register map package");

                -- Unused addresses read zero
                for a in RegBlock_c / 4 + 1 to RegImagesDone_c / 4 - 1 loop
                    chk(4 * a, x"00000000", "unused address 0x" & to_hstring(to_unsigned(4 * a, 8)));
                end loop;

                for a in RegEccUncorrectable_c / 4 + 1 to 63 loop
                    if a /= RegLimits_c / 4 then
                        chk(4 * a, x"00000000", "unused address 0x" & to_hstring(to_unsigned(4 * a, 8)));
                    end if;
                end loop;

                -- Writes to read-only registers and unused addresses change nothing
                for i in 0 to 11 loop
                    wr(4 * i, not word(i));
                end loop;

                wr(16#30#, x"FFFFFFFF");
                wr(16#FC#, x"FFFFFFFF");

                for i in 0 to 11 loop
                    chk(4 * i, word(i), "register at 0x" & to_hstring(to_unsigned(4 * i, 8)) & " after a write");
                end loop;

                chk(16#30#, x"00000000", "unused address after a write");
                Exp_v := (others => 0);
                chkCounters("counters after the writes to the other registers");

                -- Runtime configuration without it (MB-RC-05): zero registers, writes without effect, the
                -- error limit values of the generics in LIMITS, zero configuration outputs
                for a in RegControl_c / 4 to RegNextLimits_c / 4 loop
                    wr(4 * a, x"FFFFFFFF");
                    chk(4 * a, x"00000000", "runtime register 0x" & to_hstring(to_unsigned(4 * a, 8)) &
                        " without the runtime configuration");
                end loop;

                chk(RegLimits_c, std_logic_vector(to_signed(ExpLimits_g, 32)), "LIMITS: values of the generics");
                wr(RegLimits_c, x"FFFFFFFF");
                chk(RegLimits_c, std_logic_vector(to_signed(ExpLimits_g, 32)), "LIMITS after a write");
                chkOutputs(0, 0, 0, 0, 0, "configuration outputs without the runtime configuration");

            elsif run("test_counters") then
                Exp_v := (others => 0);

                -- Every input increments its own counter only
                for i in 0 to NumCnt_c - 1 loop
                    pulses(i, 3 + i, i mod 3);
                    Exp_v(i) := 3 + i;
                    chkCounters("pulses on input " & to_string(i));
                end loop;

                -- Back-to-back pulses
                pulses(2, 100, 0);
                Exp_v(2) := Exp_v(2) + 100;
                chkCounters("back-to-back pulses");

                -- A write clears one counter
                for i in 0 to NumCnt_c - 1 loop
                    wr(CntAddr_c(i), x"00000000");
                    Exp_v(i) := 0;
                    chkCounters("clear of counter " & to_string(i));
                end loop;

                -- An event in the cycle of the clearing write counts after the clearing: back-to-back pulses
                -- during one write; the slave writes in the cycle in which BValid rises, from which the
                -- monitor counts the pulses
                for i in 0 to NumCnt_c - 1 loop
                    MonSel     <= i;
                    PulseSel   <= i;
                    PulseCount <= 200;
                    PulseGap   <= 0;
                    PulseStart <= true;
                    syncClk;
                    PulseStart <= false;

                    for c in 1 to 20 loop
                        syncClk;
                    end loop;

                    wr(CntAddr_c(i), x"00000000");
                    wait until PulseDone;
                    regRead(AXILITE_VVCT, Axi_c, CntAddr_c(i), D_v);
                    check_value(MonCount > 0 and MonCount < 200, ERROR, "clear during the pulses");
                    check_value(to_integer(unsigned(D_v)), MonCount, ERROR,
                                "counter " & to_string(i) & ": pulses from the cycle of the clearing write on");
                    wr(CntAddr_c(i), x"00000000");
                end loop;

                Exp_v := (others => 0);
                chkCounters("all cleared");

            elsif run("test_runtime_config") then
                Words_v := parseIntVec(ExpWords_g);
                Lim_v   := std_logic_vector(to_signed(ExpLimits_g, 32));
                LimA_v  := to_integer(unsigned(Lim_v(15 downto 0)));
                LimR_v  := to_integer(unsigned(Lim_v(31 downto 16)));
                -- The core has taken the maxima (the reset values of the core)
                Act_XSize    <= std_logic_vector(to_unsigned(XSize_g, 17));
                Act_YSize    <= std_logic_vector(to_unsigned(YSize_g, 17));
                Act_ZSize    <= std_logic_vector(to_unsigned(ZSize_g, 17));
                Act_AbsLimit <= Lim_v(15 downto 0);
                Act_RelLimit <= Lim_v(31 downto 16);

                -- ID to BLOCK as in the file (GENERICS.RUNTIME_CONFIG = '1'); reset values of the pending
                -- registers and of the outputs (MB-RC-01)
                for i in 0 to 11 loop
                    chk(4 * i, word(i), "register at 0x" & to_hstring(to_unsigned(4 * i, 8)));
                end loop;

                chk(RegNextX_c, w32(XSize_g), "NEXT_X after the reset");
                chk(RegNextY_c, w32(YSize_g), "NEXT_Y after the reset");
                chk(RegNextZ_c, w32(ZSize_g), "NEXT_Z after the reset");
                chk(RegNextLimits_c, std_logic_vector(to_signed(ExpLimits_g, 32)), "NEXT_LIMITS after the reset");
                chk(RegLimits_c, std_logic_vector(to_signed(ExpLimits_g, 32)), "LIMITS after the reset");
                chkStatus('0', '0', "after the reset");
                chkOutputs(XSize_g, YSize_g, ZSize_g, LimA_v, LimR_v, "after the reset");

                -- Readback of the pending registers
                setNext(XSize_g - 1, 1, ZSize_g, 1, 1);
                chk(RegNextX_c, w32(XSize_g - 1), "NEXT_X readback");
                chk(RegNextY_c, w32(1), "NEXT_Y readback");
                chk(RegNextZ_c, w32(ZSize_g), "NEXT_Z readback");
                chk(RegNextLimits_c, limits(1, 1), "NEXT_LIMITS readback");

                -- A valid COMMIT: outputs and CFG_PENDING; Cfg_Taken clears CFG_PENDING
                setNext(XSize_g, YSize_g, ZSize_g, 1, 1);
                commit;
                chkStatus('0', '1', "valid COMMIT");
                chkOutputs(XSize_g, YSize_g, ZSize_g, 1, 1, "valid COMMIT");
                take;
                chkStatus('0', '0', "after Cfg_Taken");

                -- The active registers read the values of the core (MB-RC-04)
                Act_XSize    <= std_logic_vector(to_unsigned(maximum(XSize_g - 1, 1), 17));
                Act_YSize    <= std_logic_vector(to_unsigned(1, 17));
                Act_ZSize    <= std_logic_vector(to_unsigned(1, 17));
                Act_AbsLimit <= std_logic_vector(to_unsigned(toInt(UseAbs_c) * AbsMax_c, 16));
                Act_RelLimit <= std_logic_vector(to_unsigned(toInt(UseRel_c) * RelMax_c, 16));
                chk(RegImageX_c, w32(maximum(XSize_g - 1, 1)), "IMAGE_X: value of the core");
                chk(RegImageY_c, w32(1), "IMAGE_Y: value of the core");
                chk(RegImageZ_c, w32(1), "IMAGE_Z: value of the core");
                chk(RegLimits_c, limits(toInt(UseAbs_c) * AbsMax_c, toInt(UseRel_c) * RelMax_c),
                    "LIMITS: values of the core");
                Sfd_v        := 0;
                if EncodingOrder_g = "BI" then
                    Sfd_v := 1;
                end if;
                chk(RegOrder_c, w32(Sfd_v * 256 + toInt(EncodingOrder_g = "BSQ")), "ORDER: M of the core (NZ = 1)");
                Act_ZSize <= std_logic_vector(to_unsigned(ZSize_g, 17));
                if EncodingOrder_g = "BI" then
                    Sfd_v := minimum(SubFrameDepth_g, ZSize_g);
                end if;
                chk(RegOrder_c, w32(Sfd_v * 256 + toInt(EncodingOrder_g = "BSQ")), "ORDER: M of the core");

                -- Every field at its bounds (MB-RC-02): valid 1 and the maximum, invalid 0 and the maximum + 1
                setNext(XSize_g, YSize_g, ZSize_g, 1, 1);
                commit;
                take;
                invalid(0, YSize_g, ZSize_g, 1, 1, "NX = 0");
                invalid(XSize_g + 1, YSize_g, ZSize_g, 1, 1, "NX above the maximum");
                invalid(XSize_g, 0, ZSize_g, 1, 1, "NY = 0");
                invalid(XSize_g, YSize_g + 1, ZSize_g, 1, 1, "NY above the maximum");
                invalid(XSize_g, YSize_g, 0, 1, 1, "NZ = 0");
                invalid(XSize_g, YSize_g, ZSize_g + 1, 1, 1, "NZ above the maximum");
                if UseAbs_c then
                    invalid(XSize_g, YSize_g, ZSize_g, AbsMax_c + 1, 1, "absolute limit above 2^DA - 1");
                end if;
                if UseRel_c then
                    invalid(XSize_g, YSize_g, ZSize_g, 1, RelMax_c + 1, "relative limit above 2^DR - 1");
                end if;
                if Wide_c then
                    invalid(1, YSize_g, ZSize_g, 1, 1, "NX = 1 with full prediction or neighbor-oriented sums");
                else
                    setNext(1, 1, 1, 0, 0);
                    commit;
                    chkStatus('0', '1', "NX = NY = NZ = 1");
                    chkOutputs(1, 1, 1, 0, 0, "NX = NY = NZ = 1");
                    take;
                end if;
                setNext(XSize_g, YSize_g, ZSize_g, toInt(UseAbs_c) * AbsMax_c, toInt(UseRel_c) * RelMax_c);
                commit;
                chkStatus('0', '1', "maxima");
                chkOutputs(XSize_g, YSize_g, ZSize_g, toInt(UseAbs_c) * AbsMax_c, toInt(UseRel_c) * RelMax_c,
                           "maxima");
                take;
                setNext(2, 1, 1, 0, 0);
                commit;
                chkOutputs(2, 1, 1, 0, 0, "minima");
                take;
                -- Values of a method not in use are not checked
                if not UseAbs_c then
                    setNext(2, 1, 1, 65535, 0);
                    commit;
                    chkStatus('0', '1', "absolute limit not in use");
                    take;
                end if;
                if not UseRel_c then
                    setNext(2, 1, 1, 0, 65535);
                    commit;
                    chkStatus('0', '1', "relative limit not in use");
                    take;
                end if;

                -- Writes to an unused address and to a read-only register leave the pending values and STATUS;
                -- a write of a pending register with byte lanes disabled changes only the enabled bytes
                setNext(5, 2, 3, 0, 0);
                wr(16#30#, x"FFFFFFFF");
                wr(RegLimits_c, x"FFFFFFFF");
                chk(RegNextX_c, w32(5), "NEXT_X after writes to other addresses");
                chk(RegNextY_c, w32(2), "NEXT_Y after writes to other addresses");
                chk(RegNextZ_c, w32(3), "NEXT_Z after writes to other addresses");
                chkStatus('0', '0', "writes to other addresses");
                wrStrb(RegNextX_c, x"0000FF06", "0001");
                chk(RegNextX_c, w32(6), "NEXT_X written with byte lane 0 only");
                wrStrb(RegNextY_c, x"00000107", "0010");
                chk(RegNextY_c, w32(16#102#), "NEXT_Y written with byte lane 1 only");

                -- Writes without effect: COMMIT and the clear of CFG_ERROR with byte lane 0 disabled or
                -- with the bit 0
                setNext(2, 1, 1, 0, 0);
                commit;
                take;
                setNext(3, 1, 1, 0, 0);
                wrStrb(RegControl_c, x"00000001", "1110");
                chkStatus('0', '0', "COMMIT with byte lane 0 disabled");
                chkOutputs(2, 1, 1, 0, 0, "COMMIT with byte lane 0 disabled");
                wr(RegControl_c, x"00000000");
                chkStatus('0', '0', "CONTROL written with COMMIT = 0");
                chkOutputs(2, 1, 1, 0, 0, "CONTROL written with COMMIT = 0");
                setNext(XSize_g, YSize_g, 0, 0, 0);
                commit;
                chkStatus('1', '0', "NZ = 0 (invalid)");
                wrStrb(RegStatus_c, x"00000002", "1110");
                chkStatus('1', '0', "clear of CFG_ERROR with byte lane 0 disabled");
                wr(RegStatus_c, x"00000000");
                chkStatus('1', '0', "STATUS written with CFG_ERROR = 0");
                wr(RegStatus_c, x"00000002");
                chkStatus('0', '0', "CFG_ERROR cleared");

                -- Without the runtime parameters (MB-RP-04): NEXT_SAMPLES to NEXT_BLOCK read zero and ignore
                -- writes, the parameter outputs stay zero, the Act_ inputs of the parameters change no register
                Act_UserData       <= (others => '1');
                Act_M              <= (others => '1');
                Act_WeightInterval <= (others => '1');
                Act_WeightVmin     <= (others => '1');
                Act_WeightVmax     <= (others => '1');
                Act_UnaryLimit     <= (others => '1');
                Act_InitCountExp   <= (others => '1');
                Act_RescaleSize    <= (others => '1');
                Act_AccuInit       <= (others => '1');
                Act_RefInterval    <= (others => '1');
                Act_ZSize          <= std_logic_vector(to_unsigned(ZSize_g, 17));

                for i in 0 to 4 loop
                    wr(NextReg_c(i), x"FFFFFFFF");
                    chk(NextReg_c(i), x"00000000", "pending parameter register " & to_string(i) &
                        " without the runtime parameters");
                end loop;

                for i in 5 to 11 loop
                    if i /= RegOrder_c / 4 then
                        chk(4 * i, word(i), "register at 0x" & to_hstring(to_unsigned(4 * i, 8)) &
                            " with the Act_ inputs of the parameters");
                    end if;
                end loop;

                setNext(2, 1, 1, 0, 0);
                commit;
                chkStatus('0', '1', "valid COMMIT without the runtime parameters");
                chkParOut((0, 0, 0, 0, 0, 0, 0, 0, 0, 0), "parameter outputs without the runtime parameters");
                take;

            elsif run("test_runtime_params") then
                Words_v := parseIntVec(ExpWords_g);
                -- The ID of version 3 and GENERICS.RUNTIME_PARAMS (MB-RP-03)
                chk(RegId_c, x"4F435003", "ID: register map version 3");
                check_value(word(1)(GenericsRuntimeParams_c), '1', ERROR, "GENERICS.RUNTIME_PARAMS in the file");
                chk(RegGenerics_c, word(1), "GENERICS");

                -- Reset values: the values of the generics in the fields in use, the read-only registers of the
                -- same layout give them (MB-RP-01)
                for i in 0 to 4 loop
                    chk(NextReg_c(i), word(RoReg_c(i) / 4) and parMask(i), "pending parameter register " &
                        to_string(i) & " after the reset");
                end loop;

                -- Readback: of all ones written the fields in use stay, every other bit reads zero
                for i in 0 to 4 loop
                    wr(NextReg_c(i), x"FFFFFFFF");
                    chk(NextReg_c(i), parMask(i), "pending parameter register " & to_string(i) & " readback");
                end loop;

                -- A write with byte lane 1 only changes only that byte (NEXT_SAMPLES.USER_DATA)
                wr(RegNextSamples_c, x"00000000");
                wrStrb(RegNextSamples_c, x"0000A5FF", "0010");
                chk(RegNextSamples_c, x"0000A500", "NEXT_SAMPLES written with byte lane 1 only");

                -- Base values: those of the generics, the pending dimensions at their maxima
                Base_v    := (UserData_g,
                              minimum(SubFrameDepth_g,
                                         ZSize_g),
                              WeightUpdateInterval_g,
                              WeightUpdateVmin_g,
                              WeightUpdateVmax_g,
                              UnaryLimit_g,
                              InitialCountExp_g,
                              RescaleCounterSize_g,
                              vecElem(parseIntVec(AccuInit_g),
                                         0),
                              RefInterval_g);
                ParLast_v := Base_v;
                setNext(XSize_g, YSize_g, ZSize_g, 0, 0);
                tryPar(Base_v, true, "values of the generics");

                -- Every parameter in use at the bounds of its range and one value beyond each (MB-RP-02, CO-RP-02)
                tryPar(withPar(Base_v, 0, 0), true, "user-defined data 0");
                tryPar(withPar(Base_v, 0, 255), true, "user-defined data 255");
                tryPar(withPar(withPar(Base_v, 3, -6), 4, -6), true, "vmin = vmax = -6");
                tryPar(withPar(withPar(Base_v, 3, 9), 4, 9), true, "vmin = vmax = 9");
                tryPar(withPar(withPar(Base_v, 3, -7), 4, 0), false, "vmin -7");
                tryPar(withPar(withPar(Base_v, 3, 10), 4, 10), false, "vmin 10");
                tryPar(withPar(withPar(Base_v, 3, 2), 4, 1), false, "vmax below vmin");
                tryPar(withPar(withPar(Base_v, 3, -6), 4, 10), false, "vmax 10");
                tryPar(withPar(Base_v, 2, 4), true, "log2 t_inc 4");
                tryPar(withPar(Base_v, 2, 11), true, "log2 t_inc 11");
                tryPar(withPar(Base_v, 2, 3), false, "log2 t_inc 3");
                tryPar(withPar(Base_v, 2, 12), false, "log2 t_inc 12");
                if UseM_c then
                    tryPar(withPar(Base_v, 1, 1), true, "M 1");
                    tryPar(withPar(Base_v, 1, minimum(SubFrameDepth_g, ZSize_g)), true, "M min(SubFrameDepth_g, NZ)");
                    tryPar(withPar(Base_v, 1, 0), false, "M 0");
                    tryPar(withPar(Base_v, 1, SubFrameDepth_g + 1), false, "M above SubFrameDepth_g");
                    -- M against the pending NZ
                    setNext(XSize_g, YSize_g, 1, 0, 0);
                    tryPar(withPar(Base_v, 1, 2), false, "M 2 with NZ 1");
                    tryPar(withPar(Base_v, 1, 1), true, "M 1 with NZ 1");
                    setNext(XSize_g, YSize_g, ZSize_g, 0, 0);
                end if;
                if UseAdp_c then
                    tryPar(withPar(Base_v, 5, 8), true, "Umax 8");
                    tryPar(withPar(Base_v, 5, 32), true, "Umax 32");
                    tryPar(withPar(Base_v, 5, 7), false, "Umax 7");
                    tryPar(withPar(Base_v, 5, 33), false, "Umax 33");
                    Par_v := withPar(withPar(Base_v, 6, G0Min_c), 7, maximum(4, G0Min_c + 1));
                    tryPar(Par_v, true, "gamma0 at its lower bound, gamma* max(4, gamma0 + 1)");
                    tryPar(withPar(Par_v, 6, G0Min_c - 1), false, "gamma0 below its lower bound");
                    tryPar(withPar(Par_v, 7, maximum(4, G0Min_c + 1) - 1), false, "gamma* below max(4, gamma0 + 1)");
                    Par_v := withPar(withPar(Base_v, 6, G0Max_c), 7, RescaleCounterSize_g);
                    tryPar(Par_v, true, "gamma0 min(8, RescaleCounterSize_g - 1), gamma* RescaleCounterSize_g");
                    tryPar(withPar(Par_v, 6, G0Max_c + 1), false, "gamma0 above its upper bound");
                    tryPar(withPar(Par_v, 7, G0Max_c), false, "gamma* = gamma0");
                    tryPar(withPar(Par_v, 7, RescaleCounterSize_g + 1), false, "gamma* above RescaleCounterSize_g");
                end if;
                if UseK_c then
                    tryPar(withPar(Base_v, 8, 0), true, "K 0");
                    tryPar(withPar(Base_v, 8, KMax_c), true, "K min(D - 2, 14)");
                    tryPar(withPar(Base_v, 8, KMax_c + 1), false, "K above min(D - 2, 14)");
                end if;
                if UseR_c then
                    tryPar(withPar(Base_v, 9, 1), true, "r 1");
                    tryPar(withPar(Base_v, 9, RefInterval_g), true, "r RefInterval_g");
                    tryPar(withPar(Base_v, 9, 0), false, "r 0");
                    tryPar(withPar(Base_v, 9, RefInterval_g + 1), false, "r above RefInterval_g");
                end if;
                -- An invalid dimension with valid parameters passes nothing either
                setNext(0, YSize_g, ZSize_g, 0, 0);
                tryPar(withPar(Base_v, 0, 17), false, "NX 0 with valid parameters");
                setNext(XSize_g, YSize_g, ZSize_g, 0, 0);

                -- The parameter fields of SAMPLES to BLOCK read the Act_ inputs (MB-RP-03)
                Par_v              := (165,
                                       3,
                                       9,
                                       -5,
                                       7,
                                       21,
                                       3,
                                       9,
                                       6,
                                       1234);
                Act_UserData       <= std_logic_vector(to_unsigned(Par_v(0), 8));
                Act_M              <= std_logic_vector(to_unsigned(Par_v(1), 17));
                Act_WeightInterval <= std_logic_vector(to_unsigned(Par_v(2), 4));
                Act_WeightVmin     <= std_logic_vector(to_signed(Par_v(3), 5));
                Act_WeightVmax     <= std_logic_vector(to_signed(Par_v(4), 5));
                Act_UnaryLimit     <= std_logic_vector(to_unsigned(Par_v(5), 6));
                Act_InitCountExp   <= std_logic_vector(to_unsigned(Par_v(6), 4));
                Act_RescaleSize    <= std_logic_vector(to_unsigned(Par_v(7), 4));
                Act_AccuInit       <= std_logic_vector(to_unsigned(Par_v(8), 4));
                Act_RefInterval    <= std_logic_vector(to_unsigned(Par_v(9), 13));

                for i in 0 to 4 loop
                    Word32_v := (word(RoReg_c(i) / 4) and not parMask(i)) or (parWord(i, Par_v) and parMask(i));
                    chk(RoReg_c(i), Word32_v, "register at 0x" & to_hstring(to_unsigned(RoReg_c(i), 8)) &
                        ": parameter fields of the core");
                end loop;

            elsif run("test_runtime_commit") then
                -- Write cycle of a COMMIT relative to the rise of AwValid (calibration); limits 1 so that the
                -- first COMMIT below (limits 0) changes every field
                setNext(XSize_g, YSize_g, ZSize_g, 1, 1);
                await_completion(AXILITE_VVCT, Axi_c, 10 us, "pending values");
                Cnt_v   := TakeCnt;
                TakeArm <= true;
                syncClk;
                TakeArm <= false;
                commit;
                await_completion(AXILITE_VVCT, Axi_c, 10 us, "calibration");

                while TakeCnt = Cnt_v loop
                    syncClk;
                end loop;

                take;
                check_value(WrDelay > 1, ERROR, "write cycle measured");
                AtomicOn <= true;

                -- COMMIT one cycle before, in and one cycle after the cycle of Cfg_Taken
                for ofs in -1 to 1 loop
                    Prev_v := CfgAll;
                    commitAt(ofs, 2 + ofs + 1, "COMMIT " & to_string(ofs) & " cycles from Cfg_Taken");
                    if ofs < 0 then
                        -- The write before the take: the core takes the new values, CFG_PENDING is cleared
                        check_value(TakeSeen(152 downto 70) = cfgVec(std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                                     std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                                     std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                                     std_logic_vector(to_unsigned((2 + ofs + 1) mod 2, 16)),
                                                                     std_logic_vector(to_unsigned((2 + ofs + 1) mod 2, 16))),
                                    ERROR, "COMMIT before Cfg_Taken: the new values are taken");
                        check_value(sameFields(TakeSeen, Prev_v) = 0, ERROR,
                                    "COMMIT before Cfg_Taken: every output changed");
                        chkStatus('0', '0', "COMMIT before Cfg_Taken");
                    else
                        -- In or after the cycle of the take: the previous values are taken, CFG_PENDING stays
                        -- set until the next take
                        check_value(TakeSeen = Prev_v, ERROR, "COMMIT in or after the cycle of Cfg_Taken: the " &
                                    "previous values are taken");
                        chkStatus('0', '1', "COMMIT in or after the cycle of Cfg_Taken");
                        take;
                        chkStatus('0', '0', "next Cfg_Taken");
                    end if;
                end loop;

                AtomicOn <= false;
                check_value(Partial, 0, ERROR, "configuration outputs change together");

            elsif run("test_reset") then
                Exp_v := (others => 0);

                for i in 0 to NumCnt_c - 1 loop
                    pulses(i, 5, 1);
                    Exp_v(i) := 5;
                end loop;

                chkCounters("before the reset");
                reset;
                Exp_v := (others => 0);
                chkCounters("after the reset");
            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Runtime configuration: write cycle of the next write (the cycle in which BValid rises) relative to the
    -- rise of AwValid; Cfg_Taken pulse TakeOfs cycles from it
    p_take : process is
        variable Cyc_v : natural;
    begin
        wait until rising_edge(Clk) and TakeArm;
        wait until rising_edge(Clk) and AwValid = '1';
        Cyc_v := 0;
        if WrDelay = 0 then

            -- Calibration on the first armed write: cycles from the rise of AwValid to the write cycle
            loop
                wait until rising_edge(Clk);
                Cyc_v := Cyc_v + 1;
                exit when BValid = '1';
            end loop;

            WrDelay <= Cyc_v;
        else

            -- After the edge at the end of the first cycle with AwValid: the pulse in the cycle WrDelay + TakeOfs
            -- cycles after it
            for i in 1 to WrDelay + TakeOfs - 1 loop
                wait until rising_edge(Clk);
            end loop;

            TakeTimed <= '1';
            wait until rising_edge(Clk);
            TakeSeen  <= CfgAll;
            TakeTimed <= '0';
        end if;
        TakeCnt <= TakeCnt + 1;
    end process;

    -- Atomicity of the configuration outputs: a clock cycle in which some but not all of them change
    p_atomic : process is
        variable Prev_v : std_logic_vector(152 downto 0) := (others => '0');
        variable Cur_v  : std_logic_vector(152 downto 0);
        variable Same_v : natural;
    begin
        wait until rising_edge(Clk);
        Cur_v  := CfgAll;
        Same_v := sameFields(Cur_v, Prev_v);
        if Rst = '0' and Same_v > 0 and Same_v < fieldsInUse and AtomicOn then
            Partial <= Partial + 1;
        end if;
        Prev_v := Cur_v;
    end process;

    -- Pulses since the last write of the slave
    p_monitor : process is
        variable BValid_v : std_logic := '0';
    begin
        wait until rising_edge(Clk);
        if BValid = '1' and BValid_v = '0' then
            MonCount <= toInt(Ev(MonSel) = '1');
        elsif Ev(MonSel) = '1' then
            MonCount <= MonCount + 1;
        end if;
        BValid_v := BValid;
    end process;

    -- Event pulses
    p_pulses : process is
    begin
        wait until PulseStart;
        PulseDone <= false;

        for n in 1 to PulseCount loop
            Ev(PulseSel) <= '1';
            wait until rising_edge(Clk);
            Ev(PulseSel) <= '0';

            for g in 1 to PulseGap loop
                wait until rising_edge(Clk);
            end loop;

        end loop;

        PulseDone <= true;
    end process;

end architecture;
