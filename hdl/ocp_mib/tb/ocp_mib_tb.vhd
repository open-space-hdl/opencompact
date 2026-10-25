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
--   carry the previous values, after the COMMIT in that cycle CFG_PENDING stays set
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

    -- Cfg_Taken pulse TakeOfs cycles after the write cycle of the next write (TakeArm; negative: before
    -- it, with the write cycle measured as WrDelay cycles after AwValid rises); the outputs in the cycle
    -- of the pulse
    signal TakeArm  : boolean := false;
    signal TakeOfs  : integer := 0;
    signal WrDelay  : natural := 0;
    signal TakeCnt  : natural := 0;
    signal TakeSeen : std_logic_vector(82 downto 0);

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
            RuntimeConfig_g        => RuntimeConfig_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => ArAddr,
            S_AxiLite_ArValid => ArValid,
            S_AxiLite_ArReady => ArReady,
            S_AxiLite_AwAddr  => AwAddr,
            S_AxiLite_AwValid => AwValid,
            S_AxiLite_AwReady => AwReady,
            S_AxiLite_WData   => WData,
            S_AxiLite_WStrb   => WStrb,
            S_AxiLite_WValid  => WValid,
            S_AxiLite_WReady  => WReady,
            S_AxiLite_BResp   => BResp,
            S_AxiLite_BValid  => BValid,
            S_AxiLite_BReady  => BReady,
            S_AxiLite_RData   => RData,
            S_AxiLite_RResp   => RResp,
            S_AxiLite_RValid  => RValid,
            S_AxiLite_RReady  => RReady,
            Ev_ImageDone      => Ev(0),
            Ev_ImageAborted   => Ev(1),
            Ev_SduError       => Ev(2),
            Ev_SduDiscarded   => Ev(3),
            Ecc_Sec           => Ev(4),
            Ecc_Ded           => Ev(5),
            Cfg_XSize         => Cfg_XSize,
            Cfg_YSize         => Cfg_YSize,
            Cfg_ZSize         => Cfg_ZSize,
            Cfg_AbsLimit      => Cfg_AbsLimit,
            Cfg_RelLimit      => Cfg_RelLimit,
            Cfg_Taken         => Cfg_Taken,
            Act_XSize         => Act_XSize,
            Act_YSize         => Act_YSize,
            Act_ZSize         => Act_ZSize,
            Act_AbsLimit      => Act_AbsLimit,
            Act_RelLimit      => Act_RelLimit
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

        -- A COMMIT whose write cycle is ofs clock cycles before (negative) or after a Cfg_Taken pulse
        procedure commitAt (ofs : integer; x : natural; msg : string) is
            variable Cnt_v : natural;
        begin
            setNext(x, x, x, x mod 2, x mod 2);
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

        variable Prev_v : std_logic_vector(82 downto 0);
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
                    Prev_v := cfgVec(Cfg_XSize, Cfg_YSize, Cfg_ZSize, Cfg_AbsLimit, Cfg_RelLimit);
                    commitAt(ofs, 2 + ofs + 1, "COMMIT " & to_string(ofs) & " cycles from Cfg_Taken");
                    if ofs < 0 then
                        -- The write before the take: the core takes the new values, CFG_PENDING is cleared
                        check_value(TakeSeen = cfgVec(std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                      std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                      std_logic_vector(to_unsigned(2 + ofs + 1, 17)),
                                                      std_logic_vector(to_unsigned((2 + ofs + 1) mod 2, 16)),
                                                      std_logic_vector(to_unsigned((2 + ofs + 1) mod 2, 16))), ERROR,
                                    "COMMIT before Cfg_Taken: the new values are taken");
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
            TakeSeen  <= cfgVec(Cfg_XSize, Cfg_YSize, Cfg_ZSize, Cfg_AbsLimit, Cfg_RelLimit);
            TakeTimed <= '0';
        end if;
        TakeCnt <= TakeCnt + 1;
    end process;

    -- Atomicity of the configuration outputs: a clock cycle in which some but not all of them change
    p_atomic : process is
        variable Prev_v : std_logic_vector(82 downto 0) := (others => '0');
        variable Cur_v  : std_logic_vector(82 downto 0);
        variable Same_v : natural;
    begin
        wait until rising_edge(Clk);
        Cur_v  := cfgVec(Cfg_XSize, Cfg_YSize, Cfg_ZSize, Cfg_AbsLimit, Cfg_RelLimit);
        Same_v := toInt(Cur_v(82 downto 66) = Prev_v(82 downto 66)) + toInt(Cur_v(65 downto 49) = Prev_v(65 downto 49)) +
                  toInt(Cur_v(48 downto 32) = Prev_v(48 downto 32)) + toInt(Cur_v(31 downto 16) = Prev_v(31 downto 16)) +
                  toInt(Cur_v(15 downto 0) = Prev_v(15 downto 0));
        if Rst = '0' and Same_v > 0 and Same_v < 5 and AtomicOn then
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
