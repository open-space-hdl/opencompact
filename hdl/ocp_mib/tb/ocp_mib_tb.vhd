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
        RefInterval_g          : positive := 4096
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

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

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
            RefInterval_g          => RefInterval_g
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
            Ecc_Ded           => Ev(5)
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
                    chk(4 * a, x"00000000", "unused address 0x" & to_hstring(to_unsigned(4 * a, 8)));
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
