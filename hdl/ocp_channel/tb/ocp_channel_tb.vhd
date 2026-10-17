---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_channel: the source cuts the test image of a configuration (tb/golden/<config>)
-- into SDUs of random length (big-endian containers of ceil(D/8) bytes, user signal of the OpenSPP
-- receive port: end mark CPTP User Application 1, Data Loss Indicator bit 12, buffer error bit 13)
-- and sends them as a byte stream; the sink compares every packet of the output stream with the
-- image compressed by the CNES reference software. The counters are read through the AXI4-Lite
-- slave with the AXI-Lite VVC of UVVM.
--
-- * test_golden: images one after the other; every packet equals the reference, IMAGES_DONE counts
--   them, the other counters stay zero
-- * test_errors: the error scenarios of the specification between correct images: faulty SDU inside
--   and at the end of an image, lost SDU inside and at the end, incomplete last container, early and
--   missing end mark, faulty SDU and lost end SDU of the same image; every packet, its error flag and
--   every counter step are checked
-- * test_ecc: single and double bit errors injected through ErrInj_* into memories of the core
--   are counted in ECC_CORRECTED and ECC_UNCORRECTABLE; the image with a corrected error is correct
-- * test_reset: a reset in the middle of an image clears the counters; the next image is correct
--
-- Documentation: hdl/ocp_channel/docs/verification_plan.md

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
entity ocp_channel_tb is
    generic (
        runner_cfg             : string;
        GoldenDir_g            : string   := "";
        -- Number of images of test_golden
        Images_g               : positive := 3;
        -- Back pressure: probability (percent) of an idle cycle of the source and of a stall of the sink
        InGapPct_g             : natural  := 0;
        OutStallPct_g          : natural  := 0;
        -- Largest SDU in samples
        MaxSdu_g               : positive := 40;
        -- Size of the header in bytes
        HeaderBytes_g          : natural  := 0;
        -- Error injection channels (test_ecc)
        EccChannels_g          : string   := "";
        -- Widths of the channel
        InStreamWidth_g        : positive := 128;
        OutStreamWidth_g       : positive := 128;
        OutWidth_g             : positive := 64;
        -- Configuration
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
        SupTableCount_g        : natural  := 0;
        SupTableData_g         : string   := "00";
        PredictionBands_g      : natural  := 3;
        PredictionMode_g       : string   := "FULL";
        LocalSum_g             : string   := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive := 64;
        WeightResolution_g     : positive := 13;
        WeightUpdateInterval_g : positive := 6;
        WeightUpdateVmin_g     : integer  := -1;
        WeightUpdateVmax_g     : integer  := 3;
        WeightExpOffsetsUsed_g : boolean  := false;
        WeightExpOffsetTable_g : boolean  := false;
        WeightExpOffsets_g     : string   := "0";
        CustomWeights_g        : boolean  := false;
        WeightInitTable_g      : boolean  := false;
        WeightInitResolution_g : natural  := 0;
        WeightInitValues_g     : string   := "0";
        Fidelity_g             : string   := "LOSSLESS";
        PeriodicUpdate_g       : boolean  := false;
        UpdatePeriodExp_g      : natural  := 0;
        AbsBandDependent_g     : boolean  := false;
        AbsBitDepth_g          : positive := 1;
        AbsErrorLimits_g       : string   := "0";
        RelBandDependent_g     : boolean  := false;
        RelBitDepth_g          : positive := 1;
        RelErrorLimits_g       : string   := "0";
        SampleRepResolution_g  : natural  := 0;
        DampingBandVarying_g   : boolean  := false;
        DampingTable_g         : boolean  := false;
        Damping_g              : string   := "0";
        OffsetBandVarying_g    : boolean  := false;
        OffsetTable_g          : boolean  := false;
        Offset_g               : string   := "0";
        UnaryLimit_g           : positive := 16;
        RescaleCounterSize_g   : positive := 6;
        InitialCountExp_g      : positive := 1;
        AccuInitBandVarying_g  : boolean  := false;
        AccuInitTable_g        : boolean  := false;
        AccuInit_g             : string   := "3";
        HybridAccuInit_g       : string   := "0";
        HybridAccuInitHigh_g   : string   := "0";
        BlockSize_g            : positive := 16;
        RestrictedCodes_g      : boolean  := false;
        RefInterval_g          : positive := 4096
    );
end entity;

architecture sim of ocp_channel_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Axi_c       : natural  := 0;
    constant RawBytes_c  : positive := 1 + toInt(DynamicRange_g > 8) + 2 * toInt(DynamicRange_g > 16);
    constant Sb_c        : positive := (DynamicRange_g + 7) / 8;
    constant Lanes_c     : positive := InStreamWidth_g / 8;
    constant OutLanes_c  : positive := OutStreamWidth_g / 8;
    constant Samples_c   : positive := XSize_g * YSize_g * ZSize_g;
    constant Periodic_c  : boolean  := PeriodicUpdate_g and Fidelity_g /= "LOSSLESS";

    constant UserWidth_c : positive                      := 22;
    constant LastMask_c  : std_logic_vector(21 downto 0) := 22x"3FC000";
    constant LastValue_c : std_logic_vector(21 downto 0) := 22x"004000";
    constant ErrorMask_c : std_logic_vector(21 downto 0) := 22x"003000";

    -- Scenario of an image (specification of ocp_channel, section 3); J is the SDU concerned
    constant Normal_c      : natural  := 0;
    constant FaultMid_c    : natural  := 1;  -- SDU J < n with the buffer error bit
    constant FaultEnd_c    : natural  := 2;  -- SDU n with the buffer error bit
    constant LostMid_c     : natural  := 3;  -- SDU J < n lost, SDU J + 1 with the Data Loss Indicator
    constant LostEnd_c     : natural  := 4;  -- SDU n lost, SDU 1 of the next image with the Data Loss Indicator
    constant LengthMid_c   : natural  := 5;  -- SDU J < n one byte short
    constant EarlyMark_c   : natural  := 6;  -- end mark on SDU J < n
    constant MissingMark_c : natural  := 7;  -- no end mark on SDU n
    constant FaultLost_c   : natural  := 8;  -- SDU J < n with the buffer error bit, SDU n lost
    constant Unchecked_c   : natural  := 9;  -- correct SDUs, the packet is not compared (double bit error)
    constant MaxPlan_c     : positive := 20;

    type Plan_t is array (1 to MaxPlan_c) of natural;

    -- Expected packets: reference image, reference image with error flag, aborted (prefix of the
    -- reference, fill bits, error flag), header only (other samples than the reference, error flag)
    constant PkGolden_c    : natural  := 0;
    constant PkGoldenErr_c : natural  := 1;
    constant PkPrefix_c    : natural  := 2;
    constant PkHeader_c    : natural  := 3;
    constant PkAny_c       : natural  := 4;
    constant PkDepth_c     : positive := 64;

    type PkArr_t is array (0 to PkDepth_c - 1) of natural;

    -- Aborted image: byte o of the output is the first k bits (0 to 7) of the expected byte e, then zero bits
    function isCut (o : natural; e : natural) return boolean is
    begin

        for k in 0 to 7 loop
            if o = (e / 2 ** (8 - k)) * 2 ** (8 - k) then
                return true;
            end if;
        end loop;

        return false;
    end function;

    signal Clk            : std_logic                                      := '0';
    signal Rst            : std_logic                                      := '1';
    signal In_Valid       : std_logic                                      := '0';
    signal In_Ready       : std_logic;
    signal In_Data        : std_logic_vector(InStreamWidth_g - 1 downto 0) := (others => '0');
    signal In_Keep        : std_logic_vector(Lanes_c - 1 downto 0)         := (others => '0');
    signal In_Last        : std_logic                                      := '0';
    signal In_User        : std_logic_vector(UserWidth_c - 1 downto 0)     := (others => '0');
    signal Lim_Valid      : std_logic                                      := '0';
    signal Lim_Ready      : std_logic;
    signal Lim_Data       : std_logic_vector(15 downto 0)                  := (others => '0');
    signal Out_Valid      : std_logic;
    signal Out_Ready      : std_logic                                      := '0';
    signal Out_Data       : std_logic_vector(OutStreamWidth_g - 1 downto 0);
    signal Out_Keep       : std_logic_vector(OutLanes_c - 1 downto 0);
    signal Out_Last       : std_logic;
    signal Out_Error      : std_logic;
    signal Ecc_Sec        : std_logic;
    signal Ecc_Ded        : std_logic;
    signal Ev_ImageError  : std_logic;
    signal ErrInj_Channel : std_logic_vector(3 downto 0)                   := (others => '0');
    signal ErrInj_Double  : std_logic                                      := '0';
    signal ErrInj_Valid   : std_logic                                      := '0';
    signal ArAddr         : std_logic_vector(7 downto 0);
    signal ArValid        : std_logic;
    signal ArReady        : std_logic;
    signal AwAddr         : std_logic_vector(7 downto 0);
    signal AwValid        : std_logic;
    signal AwReady        : std_logic;
    signal WData          : std_logic_vector(31 downto 0);
    signal WStrb          : std_logic_vector(3 downto 0);
    signal WValid         : std_logic;
    signal WReady         : std_logic;
    signal BResp          : std_logic_vector(1 downto 0);
    signal BValid         : std_logic;
    signal BReady         : std_logic;
    signal RData          : std_logic_vector(31 downto 0);
    signal RResp          : std_logic_vector(1 downto 0);
    signal RValid         : std_logic;
    signal RReady         : std_logic;

    -- Job: plan of the images; the source writes the expected packets, the sink counts the checked ones
    signal JobStart  : natural  := 0;
    signal JobImages : positive := 1;
    signal JobPlan   : Plan_t   := (others => Normal_c);
    signal SrcDone   : natural  := 0;
    signal Pk        : PkArr_t;
    signal PkCount   : natural  := 0;
    signal PkChecked : natural  := 0;
    signal PkDrop    : boolean  := false;

    -- Expected counter steps of the source model
    signal ExpDone    : natural := 0;
    signal ExpAborted : natural := 0;
    signal ExpSduErr  : natural := 0;
    signal ExpDisc    : natural := 0;
    signal EvCount    : natural := 0;

    -- Resets of the DUT: the source model starts its counters again
    signal Resets : natural := 0;

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_channel
        generic map (
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
            SupTableCount_g        => SupTableCount_g,
            SupTableData_g         => hexToSlv(SupTableData_g),
            PredictionBands_g      => PredictionBands_g,
            PredictionMode_g       => PredictionMode_g,
            LocalSum_g             => LocalSum_g,
            RegisterSize_g         => RegisterSize_g,
            WeightResolution_g     => WeightResolution_g,
            WeightUpdateInterval_g => WeightUpdateInterval_g,
            WeightUpdateVmin_g     => WeightUpdateVmin_g,
            WeightUpdateVmax_g     => WeightUpdateVmax_g,
            WeightExpOffsetsUsed_g => WeightExpOffsetsUsed_g,
            WeightExpOffsetTable_g => WeightExpOffsetTable_g,
            WeightExpOffsets_g     => parseIntVec(WeightExpOffsets_g),
            CustomWeights_g        => CustomWeights_g,
            WeightInitTable_g      => WeightInitTable_g,
            WeightInitResolution_g => WeightInitResolution_g,
            WeightInitValues_g     => parseIntVec(WeightInitValues_g),
            Fidelity_g             => Fidelity_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsBitDepth_g          => AbsBitDepth_g,
            AbsErrorLimits_g       => parseIntVec(AbsErrorLimits_g),
            RelBandDependent_g     => RelBandDependent_g,
            RelBitDepth_g          => RelBitDepth_g,
            RelErrorLimits_g       => parseIntVec(RelErrorLimits_g),
            SampleRepResolution_g  => SampleRepResolution_g,
            DampingBandVarying_g   => DampingBandVarying_g,
            DampingTable_g         => DampingTable_g,
            Damping_g              => parseIntVec(Damping_g),
            OffsetBandVarying_g    => OffsetBandVarying_g,
            OffsetTable_g          => OffsetTable_g,
            Offset_g               => parseIntVec(Offset_g),
            UnaryLimit_g           => UnaryLimit_g,
            RescaleCounterSize_g   => RescaleCounterSize_g,
            InitialCountExp_g      => InitialCountExp_g,
            AccuInitBandVarying_g  => AccuInitBandVarying_g,
            AccuInitTable_g        => AccuInitTable_g,
            AccuInit_g             => parseIntVec(AccuInit_g),
            HybridAccuInit_g       => parseIntVec(HybridAccuInit_g),
            HybridAccuInitHigh_g   => parseIntVec(HybridAccuInitHigh_g),
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g,
            OutWidth_g             => OutWidth_g,
            InStreamWidth_g        => InStreamWidth_g,
            OutStreamWidth_g       => OutStreamWidth_g,
            UserWidth_g            => UserWidth_c,
            UserLastMask_g         => LastMask_c,
            UserLastValue_g        => LastValue_c,
            UserErrorMask_g        => ErrorMask_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Valid          => In_Valid,
            In_Ready          => In_Ready,
            In_Data           => In_Data,
            In_Keep           => In_Keep,
            In_Last           => In_Last,
            In_User           => In_User,
            Lim_Valid         => Lim_Valid,
            Lim_Ready         => Lim_Ready,
            Lim_Data          => Lim_Data,
            Out_Valid         => Out_Valid,
            Out_Ready         => Out_Ready,
            Out_Data          => Out_Data,
            Out_Keep          => Out_Keep,
            Out_Last          => Out_Last,
            Out_Error         => Out_Error,
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
            Ecc_Sec           => Ecc_Sec,
            Ecc_Ded           => Ecc_Ded,
            Ev_ImageError     => Ev_ImageError,
            ErrInj_Channel    => ErrInj_Channel,
            ErrInj_Double     => ErrInj_Double,
            ErrInj_Valid      => ErrInj_Valid
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
        variable Job_v      : natural := 0;
        variable Plan_v     : Plan_t;
        variable Channels_v : integer_vector(0 to 15);
        variable NCh_v      : natural;
        variable D_v        : std_logic_vector(31 downto 0);

        procedure syncClk is
        begin
            wait until rising_edge(Clk);
        end procedure;

        procedure chk (addr : natural; value : natural; msg : string) is
        begin
            regCheck(AXILITE_VVCT, Axi_c, addr, std_logic_vector(to_unsigned(value, 32)), msg);
        end procedure;

        procedure reset is
        begin
            Rst    <= '1';
            PkDrop <= true;
            Resets <= Resets + 1;
            wait for 5 * ClkPeriod_c;
            syncClk;
            PkDrop <= false;
            Rst    <= '0';
            syncClk;
        end procedure;

        -- Runs a job and waits until the sink has checked every expected packet
        procedure job (images : positive; plan : Plan_t) is
        begin
            JobImages <= images;
            JobPlan   <= plan;
            Job_v     := Job_v + 1;
            JobStart  <= Job_v;
            wait until SrcDone = Job_v;

            while PkChecked /= PkCount loop
                syncClk;
            end loop;

            for i in 1 to 20 loop
                syncClk;
            end loop;

        end procedure;

        -- Counters of the status registers against the source model
        procedure chkCounters (msg : string) is
        begin
            chk(RegImagesDone_c, ExpDone, msg & ": IMAGES_DONE");
            chk(RegImagesAborted_c, ExpAborted, msg & ": IMAGES_ABORTED");
            chk(RegSduErrors_c, ExpSduErr, msg & ": SDU_ERRORS");
            chk(RegSdusDiscarded_c, ExpDisc, msg & ": SDUS_DISCARDED");
        end procedure;

        procedure inject (channel : natural; double : std_logic) is
        begin
            ErrInj_Channel <= std_logic_vector(to_unsigned(channel, 4));
            ErrInj_Double  <= double;
            ErrInj_Valid   <= '1';
            syncClk;
            ErrInj_Valid   <= '0';
        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        await_uvvm_initialization(VOID);
        disable_log_msg(ALL_MESSAGES);
        enable_log_msg(ID_LOG_HDR);
        enable_log_msg(ID_SEQUENCER);
        shared_axilite_vvc_config(Axi_c).bfm_config.max_wait_cycles := 1000;
        reset;

        while test_suite loop
            if run("test_golden") then
                chk(RegId_c, 16#4F435001#, "ID");
                job(Images_g, (others => Normal_c));
                check_value(ExpDone, Images_g, ERROR, "model: images done");
                chkCounters("correct images");
                check_value(EvCount, 0, ERROR, "no framing error event");

            elsif run("test_errors") then
                Plan_v     := (others => Normal_c);
                Plan_v(2)  := FaultMid_c;
                Plan_v(4)  := FaultEnd_c;
                Plan_v(5)  := LostMid_c;
                Plan_v(7)  := LostEnd_c;      -- image 8 swallowed
                Plan_v(9)  := LengthMid_c;
                Plan_v(10) := EarlyMark_c;
                Plan_v(12) := MissingMark_c;  -- image 13 swallowed
                Plan_v(14) := FaultLost_c;    -- image 15 swallowed
                job(17, Plan_v);
                chkCounters("error scenarios");
                check_value(EvCount, ExpAborted, ERROR, "one framing error event per image with an error");

            elsif run("test_ecc") then
                Channels_v                 := (others => 0);
                NCh_v                      := parseIntVec(EccChannels_g)'length;
                Channels_v(0 to NCh_v - 1) := parseIntVec(EccChannels_g);

                for i in 0 to NCh_v - 1 loop
                    -- Single bit error: corrected and counted; the image is correct
                    reset;
                    inject(Channels_v(i), '0');
                    job(1, (others => Normal_c));
                    regRead(AXILITE_VVCT, Axi_c, RegEccCorrected_c, D_v);
                    check_value(unsigned(D_v) > 0, ERROR, "channel " & to_string(Channels_v(i)) & ": ECC_CORRECTED");
                    chk(RegEccUncorrectable_c, 0, "channel " & to_string(Channels_v(i)) & ": ECC_UNCORRECTABLE");
                    -- Double bit error: counted (the image is not compared)
                    reset;
                    inject(Channels_v(i), '1');
                    job(1, (others => Unchecked_c));
                    regRead(AXILITE_VVCT, Axi_c, RegEccUncorrectable_c, D_v);
                    check_value(unsigned(D_v) > 0, ERROR,
                                "channel " & to_string(Channels_v(i)) & ": ECC_UNCORRECTABLE");
                end loop;

            elsif run("test_reset") then
                job(1, (others => Normal_c));
                chkCounters("before the reset");
                -- A reset in the middle of an image
                JobImages <= 1;
                JobPlan   <= (others => Normal_c);
                Job_v     := Job_v + 1;
                JobStart  <= Job_v;

                for c in 1 to Samples_c / 2 loop
                    syncClk;
                end loop;

                reset;
                if SrcDone /= Job_v then
                    wait until SrcDone = Job_v;
                end if;
                reset;
                chk(RegImagesDone_c, 0, "IMAGES_DONE after the reset");
                job(1, (others => Normal_c));
                chkCounters("after the reset");
            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Source: SDUs of the test image with the model of the input adapter and of the counters
    -----------------------------------------------------------------------------------------------
    p_source : process is
        type SduSizes_t is array (1 to 4096) of natural;
        type Smp_t is array (0 to 4095) of std_logic_vector(31 downto 0);

        variable Sizes_v   : SduSizes_t;
        variable NSdu_v    : natural;
        variable Smp_v     : Smp_t;
        variable Discard_v : boolean;
        variable DliNext_v : boolean;
        variable Abort_v   : boolean;
        variable Pk_v      : natural;
        variable Done_v    : natural;
        variable Aborted_v : natural;
        variable SduErr_v  : natural;
        variable Disc_v    : natural;
        variable Byte_v    : natural;
        variable Eof_v     : boolean;

        file Img_f : ByteFile_t;

        procedure expect (kind : natural) is
        begin
            Pk(Pk_v mod PkDepth_c) <= kind;
            Pk_v                   := Pk_v + 1;
            PkCount                <= Pk_v;
            if kind = PkGolden_c or kind = PkAny_c then
                Done_v := Done_v + 1;
            else
                Aborted_v := Aborted_v + 1;
            end if;
            ExpDone    <= Done_v;
            ExpAborted <= Aborted_v;
        end procedure;

        -- Sends one SDU of n samples (one byte short with short) with the end mark and the fault bits
        procedure sdu (n : positive; mark : boolean; dli : boolean; ded : boolean; short : boolean) is
            variable User_v  : std_logic_vector(UserWidth_c - 1 downto 0);
            variable Bytes_v : natural;
            variable Lane_v  : natural;
            variable K_v     : natural;
            variable B_v     : std_logic_vector(7 downto 0);
            variable Fault_v : boolean;
        begin
            User_v := std_logic_vector(to_unsigned(random(0, 2 ** 11 - 1), UserWidth_c));
            if mark then
                User_v(21 downto 14) := x"01";
            else
                User_v(21 downto 14) := std_logic_vector(to_unsigned(2 * random(0, 1), 8));
            end if;
            User_v(12) := toSl(dli);
            User_v(13) := toSl(ded);
            Bytes_v    := Sb_c * n;
            if short then
                Bytes_v := Bytes_v - 1;
            end if;

            -- Model of the input adapter
            Fault_v := dli or ded or (Bytes_v mod Sb_c /= 0);
            if Discard_v then
                Disc_v := Disc_v + 1;
                if mark then
                    Discard_v := false;
                end if;
            elsif Fault_v then
                SduErr_v := SduErr_v + 1;
                if not mark then
                    Discard_v := true;
                end if;
            end if;
            ExpSduErr <= SduErr_v;
            ExpDisc   <= Disc_v;

            -- Beats: byte k of the SDU in lane k mod Lanes_c; the containers big-endian
            K_v := 0;

            while K_v < Bytes_v loop

                while random(0, 99) < InGapPct_g and Rst = '0' loop
                    In_Valid <= '0';
                    wait until rising_edge(Clk);
                end loop;

                for l in 0 to Lanes_c - 1 loop
                    Lane_v := K_v + l;
                    if Lane_v < Bytes_v then
                        B_v                             := Smp_v(Lane_v / Sb_c)(8 * (Sb_c - 1 - Lane_v mod Sb_c) + 7 downto 8 * (Sb_c - 1 - Lane_v mod Sb_c));
                        In_Data(8 * l + 7 downto 8 * l) <= B_v;
                        In_Keep(l)                      <= '1';
                    else
                        In_Data(8 * l + 7 downto 8 * l) <= (others => '0');
                        In_Keep(l)                      <= '0';
                    end if;
                end loop;

                In_Valid <= '1';
                In_Last  <= toSl(K_v + Lanes_c >= Bytes_v);
                if K_v + Lanes_c >= Bytes_v then
                    In_User <= User_v;
                else
                    In_User <= std_logic_vector(to_unsigned(random(0, 2 ** 22 - 1), UserWidth_c));
                end if;

                loop
                    wait until rising_edge(Clk);
                    exit when In_Ready = '1' or Rst = '1';
                end loop;

                Abort_v := Rst = '1';
                exit when Abort_v;
                K_v     := K_v + Lanes_c;
            end loop;

            In_Valid <= '0';
            In_Last  <= '0';
        end procedure;

        variable Plan_v    : natural;
        variable J_v       : natural;
        variable Mark_v    : boolean;
        variable Rem_v     : natural;
        variable Swallow_v : boolean;
        variable Resets_v  : natural := 0;
    begin
        wait on JobStart;
        Abort_v   := false;
        Discard_v := false;
        DliNext_v := false;
        Pk_v      := PkCount;
        -- A reset cleared the counters of the DUT
        if Resets /= Resets_v then
            Resets_v  := Resets;
            Done_v    := 0;
            Aborted_v := 0;
            SduErr_v  := 0;
            Disc_v    := 0;
        end if;

        for img in 1 to JobImages loop
            Plan_v := JobPlan(img);

            -- SDU lengths: random, a few single-sample SDUs, at least three SDUs
            NSdu_v := 0;
            Rem_v  := Samples_c;

            while Rem_v > 0 loop
                NSdu_v := NSdu_v + 1;
                if random(0, 9) = 0 then
                    Sizes_v(NSdu_v) := 1;
                else
                    Sizes_v(NSdu_v) := minimum(Rem_v, random(1, minimum(MaxSdu_g, maximum(1, Samples_c / 3))));
                end if;
                Rem_v := Rem_v - Sizes_v(NSdu_v);
            end loop;

            J_v := random(1, maximum(NSdu_v - 1, 1));

            -- Expected packets; after a lost end SDU, a missing end mark or a faulty SDU with a lost end SDU
            -- the next image produces no packet
            Swallow_v := false;
            if img > 1 then
                Swallow_v := JobPlan(img - 1) = LostEnd_c or JobPlan(img - 1) = MissingMark_c or
                             JobPlan(img - 1) = FaultLost_c;
            end if;

            case Plan_v is
                when Normal_c =>
                    if not Swallow_v then
                        expect(PkGolden_c);
                    end if;
                when Unchecked_c => expect(PkAny_c);
                when FaultMid_c | FaultLost_c => expect(PkPrefix_c);
                when FaultEnd_c | MissingMark_c => expect(PkGoldenErr_c);
                when LostMid_c | LostEnd_c | LengthMid_c => expect(PkHeader_c);
                when EarlyMark_c =>
                    expect(PkPrefix_c);
                    expect(PkHeader_c);
                when others => null;
            end case;

            -- SDUs of the image
            file_open(Img_f, GoldenDir_g & "/image.raw", read_mode);

            for s in 1 to NSdu_v loop

                for i in 0 to Sizes_v(s) - 1 loop
                    Smp_v(i) := (others => '0');

                    for b in 0 to RawBytes_c - 1 loop
                        readByte(Img_f, Byte_v, Eof_v);
                        Smp_v(i)(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(Byte_v, 8));
                    end loop;

                end loop;

                Mark_v := s = NSdu_v;
                if Plan_v = EarlyMark_c and s = J_v then
                    Mark_v := true;
                end if;
                if Plan_v = MissingMark_c and s = NSdu_v then
                    Mark_v := false;
                end if;

                if (Plan_v = LostMid_c and s = J_v) or ((Plan_v = LostEnd_c or Plan_v = FaultLost_c) and s = NSdu_v) then
                    null;   -- lost
                else
                    sdu(Sizes_v(s), Mark_v,
                        (Plan_v = LostMid_c and s = J_v + 1) or (DliNext_v and s = 1),
                        ((Plan_v = FaultMid_c or Plan_v = FaultLost_c) and s = J_v) or (Plan_v = FaultEnd_c and s = NSdu_v),
                        Plan_v = LengthMid_c and s = J_v);
                end if;
                exit when Abort_v;
            end loop;

            file_close(Img_f);
            exit when Abort_v;
            DliNext_v := Plan_v = LostEnd_c or Plan_v = FaultLost_c;
        end loop;

        SrcDone <= JobStart;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Error limit values (periodic error limit updating): the values of every image in turn
    -----------------------------------------------------------------------------------------------
    p_limits : process is
        variable Hi_v  : natural;
        variable Lo_v  : natural;
        variable Eof_v : boolean;

        file Lim_f : ByteFile_t;
    begin
        if not Periodic_c then
            wait;
        end if;
        wait on JobStart;

        for img in 1 to JobImages loop
            file_open(Lim_f, GoldenDir_g & "/error_limits.bin", read_mode);

            loop
                readByte(Lim_f, Hi_v, Eof_v);
                readByte(Lim_f, Lo_v, Eof_v);
                exit when Eof_v;
                Lim_Valid <= '1';
                Lim_Data  <= std_logic_vector(to_unsigned(Hi_v * 256 + Lo_v, 16));
                wait until rising_edge(Clk) and (Lim_Ready = '1' or Rst = '1');
                Lim_Valid <= '0';
                exit when Rst = '1';
            end loop;

            file_close(Lim_f);
        end loop;

    end process;

    -----------------------------------------------------------------------------------------------
    -- Sink: every packet against the reference image of the CNES reference software
    -----------------------------------------------------------------------------------------------
    p_sink : process is
        variable Exp_v  : natural;
        variable Eof_v  : boolean;
        variable Cnt_v  : natural;
        variable Gap_v  : boolean;
        variable Byte_v : natural;
        variable Same_v : boolean;
        variable Kind_v : natural;
        variable Got_v  : natural := 0;

        file Ref_f : ByteFile_t;
    begin
        wait until rising_edge(Clk);
        if PkDrop then
            -- Packets of an image that a reset or a double bit error made unpredictable
            Got_v     := PkCount;
            PkChecked <= Got_v;
            Out_Ready <= '1';
        elsif Got_v < PkCount then
            Kind_v := Pk(Got_v mod PkDepth_c);
            file_open(Ref_f, GoldenDir_g & "/compressed.bin", read_mode);
            Cnt_v  := 0;
            Same_v := true;
            readByte(Ref_f, Exp_v, Eof_v);

            loop
                Out_Ready <= toSl(random(0, 99) >= OutStallPct_g);
                wait until rising_edge(Clk);
                exit when PkDrop;
                if Out_Valid = '1' and Out_Ready = '1' then
                    if Out_Last = '0' then
                        check_value(Out_Error, '0', ERROR, "packet " & to_string(Got_v) & ": error flag only on the last beat");
                    end if;
                    Gap_v := false;

                    for b in 0 to OutLanes_c - 1 loop
                        if Out_Keep(b) = '1' then
                            check_value(not Gap_v, ERROR, "packet " & to_string(Got_v) & ": valid bytes contiguous");
                            Byte_v := to_integer(unsigned(Out_Data(8 * b + 7 downto 8 * b)));
                            if Kind_v = PkAny_c then
                                null;
                            elsif Kind_v = PkGolden_c or Kind_v = PkGoldenErr_c then
                                check_value(not Eof_v, ERROR, "packet " & to_string(Got_v) & ": no byte beyond the end");
                                check_value(Byte_v, Exp_v, ERROR, "packet " & to_string(Got_v) & " byte " & to_string(Cnt_v));
                            elsif Cnt_v < HeaderBytes_g then
                                check_value(Byte_v, Exp_v, ERROR, "packet " & to_string(Got_v) & " header byte " & to_string(Cnt_v));
                            elsif Kind_v = PkPrefix_c and Same_v and (Eof_v or Byte_v /= Exp_v) then
                                -- Aborted image: end of the prefix, first bits of the byte, then fill bits
                                Same_v := false;
                                check_value(not Eof_v and isCut(Byte_v, Exp_v), ERROR,
                                            "packet " & to_string(Got_v) & " byte " & to_string(Cnt_v) & ": prefix, then fill bits");
                            elsif Kind_v = PkPrefix_c and not Same_v then
                                check_value(Byte_v, 0, ERROR, "packet " & to_string(Got_v) & " byte " & to_string(Cnt_v) & ": fill bits");
                            end if;
                            Cnt_v := Cnt_v + 1;
                            readByte(Ref_f, Exp_v, Eof_v);
                        else
                            check_value(Out_Last, '1', ERROR, "packet " & to_string(Got_v) & ": all bytes valid except in the last beat");
                            Gap_v := true;
                        end if;
                    end loop;

                    if Out_Last = '1' and Kind_v /= PkAny_c then
                        check_value(Out_Error, toSl(Kind_v /= PkGolden_c), ERROR, "packet " & to_string(Got_v) & ": error flag");
                        check_value(Cnt_v mod OutputWordSize_g, 0, ERROR, "packet " & to_string(Got_v) & ": multiple of B bytes");
                        check_value(Cnt_v >= HeaderBytes_g, ERROR, "packet " & to_string(Got_v) & ": complete header");
                        if Kind_v = PkGolden_c or Kind_v = PkGoldenErr_c then
                            check_value(Eof_v, ERROR, "packet " & to_string(Got_v) & ": complete image");
                        end if;
                    end if;
                    exit when Out_Last = '1';
                end if;
            end loop;

            file_close(Ref_f);
            Out_Ready <= '0';
            if not PkDrop then
                Got_v     := Got_v + 1;
                PkChecked <= Got_v;
            end if;
        else
            -- No packet expected: none may arrive
            Out_Ready <= '1';
            check_value(Out_Valid, '0', ERROR, "no packet expected");
        end if;
    end process;

    -- Framing error events
    p_events : process is
    begin
        wait until rising_edge(Clk);
        if Rst = '1' then
            EvCount <= 0;
        elsif Ev_ImageError = '1' then
            EvCount <= EvCount + 1;
        end if;
    end process;

end architecture;
