---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_core: compresses the test image of a configuration (tb/golden/<config>) and
-- compares the compressed image byte by byte with the image compressed by the CNES reference
-- software, including the end of the image. The test sequencer runs jobs of one or several images;
-- a reset aborts a job.
--
-- * test_golden: several images one after the other (throughput against the model)
-- * test_ecc: a single and a double bit error injected into every memory of the configuration; a
--   corrected error leaves the compressed image unchanged, a detected double error is signalled,
--   and after a reset the next image is correct
-- * test_reset: resets at random times of an image (header, body, tail), each followed by a
--   correct image
-- * test_framing (UseInLast_g): images whose In_Last comes early (aborted: the compressed image of
--   the samples taken, tb/golden/<config>/aborted_<n>.bin, with Out_Error), also back to back, or
--   is missing (complete image with
--   Out_Error, the samples up to the next In_Last are discarded), images ended with In_Error
--   (CO-FR-08: on the last sample a complete image with Out_Error, early an abort, without In_Last
--   or on discarded samples ignored), between correct images and followed by resets at random times
-- * test_runtime (RuntimeConfig_g): the image sequence of tb/golden/<config>/runtime.txt back to
--   back, every image with its own dimensions and error limit values; the configuration inputs
--   carry the values of the next image from the cycle after the take; Cfg_Taken once per image,
--   the Act_ outputs show the values of the image, the first sample of every image in the cycle
--   of the throughput model
-- * test_runtime_timing: the configuration inputs change two cycles before, in the cycle of and
--   two cycles after the acceptance of the first sample, and in the middle of an image; with the
--   image framing images aborted by an early In_Last and images with a missing In_Last
-- * test_runtime_range: the images of range.txt, configuration inputs outside their ranges taken
--   as the nearest valid values (CO-RC-07)
-- * test_runtime_queue: the images of queue.txt (the smallest images first) with Out_Ready held low
--   until the core holds back a sample for 1000 clock cycles (the configuration queue full), then
--   released; every image is compared, at least 16 images were taken before the stall; with
--   QueueHoldBytes_g (queuehold.txt) Out_Ready is held low only after the header and some bytes of the
--   body of a larger first image, so that the coder still takes items of that image while the header
--   pointer of the queue has passed it
--
-- With RuntimeParams_g every image of the lists also has its own runtime parameters: the parameter
-- inputs carry them with the configuration, the Act_ outputs of the parameters show the values taken
-- (test_runtime, test_runtime_range, test_runtime_queue).
--
-- With UseInLast_g the source sets In_Last on the last sample of every image; without it In_Last
-- and In_Error are random (ignored by the core).
--
-- Documentation: hdl/ocp_core/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.textio.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_run_context;

library work;
    use work.ocp_pkg.all;
    use work.ocp_tb_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_core_tb is
    generic (
        runner_cfg             : string;
        GoldenDir_g            : string   := "";
        -- Number of images compressed one after the other (test_golden)
        Images_g               : positive := 2;
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g             : natural  := 0;
        OutStallPct_g          : natural  := 0;
        -- Largest number of cycles between the acceptance of the first and of the last sample of all
        -- images (throughput model tools/ocp_throughput.py); 0: not checked
        ExpCycles_g            : natural  := 0;
        -- Cycles between the acceptance of the first samples of the first two images (throughput model,
        -- image_period); 0: not checked
        ExpPeriod_g            : natural  := 0;
        -- Acceptance cycle of the first sample of every image relative to the first (throughput model,
        -- issue_cycles); empty: not checked
        ExpStarts_g            : string   := "";
        -- Upper bound on the size of a compressed image in bytes (ocp_model.max_image_bytes); 0: not
        -- checked
        MaxBytes_g             : natural  := 0;
        -- Error injection channels of the memories of the configuration (test_ecc)
        EccChannels_g          : string   := "";
        -- Number of resets at random times (test_reset)
        Resets_g               : natural  := 8;
        -- Width of the compressed image interface in bits
        OutWidth_g             : positive := 8;
        -- Image framing with In_Last; size of the header in bytes; samples with the early In_Last of the
        -- aborted images of tb/golden/<config>/aborted_<n>.bin (test_framing)
        UseInLast_g            : boolean  := false;
        HeaderBytes_g          : natural  := 0;
        AbortPos_g             : string   := "0";
        -- Runtime configuration: image list tb/golden/<config>/<RtList_g>.txt (runtime or range) and
        -- its number of images (ExpStarts_g: the first sample of every image, taken with its
        -- configuration)
        RuntimeConfig_g        : boolean  := false;
        RtList_g               : string   := "runtime";
        RtImages_g             : natural  := 0;
        -- Runtime parameters: the lines of the image list also hold the driven and the taken parameters
        RuntimeParams_g        : boolean  := false;
        -- Queue test: the output is held low after this many bytes of the first image (0: from the start)
        QueueHoldBytes_g       : natural  := 0;
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

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_core_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := 1 + toInt(DynamicRange_g > 8) + 2 * toInt(DynamicRange_g > 16);
    constant Periodic_c  : boolean  := PeriodicUpdate_g and Fidelity_g /= "LOSSLESS";
    constant Samples_c   : positive := XSize_g * YSize_g * ZSize_g;

    -- Framing of an image of a job: correct, In_Last early (on sample Pos), In_Last missing (Pos
    -- further samples to discard, the last of them with In_Last); with In_Error (CO-FR-08): on the
    -- last sample with In_Last, on the early In_Last, without In_Last on sample Pos, on the samples
    -- discarded after a missing In_Last
    constant Normal_c     : natural  := 0;
    constant Early_c      : natural  := 1;
    constant Missing_c    : natural  := 2;
    constant Flagged_c    : natural  := 3;
    constant EarlyErr_c   : natural  := 4;
    constant StrayErr_c   : natural  := 5;
    constant MissingErr_c : natural  := 6;
    constant MaxPlan_c    : positive := 16;

    type Plan_r is record
        Kind : natural;
        Pos  : natural;
    end record;

    type Plan_t is array (1 to MaxPlan_c) of Plan_r;

    constant NormalPlan_c : Plan_t := (others => (Normal_c, 0));

    -- The image ends early (abort)
    function isEarly (kind : natural) return boolean is
    begin
        return kind = Early_c or kind = EarlyErr_c;
    end function;

    -- In_Last on the last sample of the image
    function isComplete (kind : natural) return boolean is
    begin
        return kind = Normal_c or kind = Flagged_c or kind = StrayErr_c;
    end function;

    -- The image ends with an error
    function isFaulty (kind : natural) return boolean is
    begin
        return kind /= Normal_c and kind /= StrayErr_c;
    end function;

    -- Sample with the early In_Last of aborted image i (the positions of AbortPos_g in turn)
    function abortPos (i : natural) return natural is
        constant P_c : integer_vector := parseIntVec(AbortPos_g);
    begin
        return P_c(P_c'low + i mod P_c'length);
    end function;

    -- Number of positions of AbortPos_g (at most 15, the plan of a job)
    function abortCount return positive is
        constant P_c : integer_vector := parseIntVec(AbortPos_g);
    begin
        return minimum(P_c'length, 15);
    end function;

    -- Time limit of a job of n images (watchdog): far above the slowest configuration with back pressure
    function jobTime (n : positive) return time is
    begin
        return n * (Samples_c * 200 + 50000) * ClkPeriod_c;
    end function;

    function twoDigits (k : natural) return string is
    begin
        if k < 10 then
            return "0" & to_string(k);
        end if;
        return to_string(k);
    end function;

    -- Line k of a text file of the golden directory as integers
    impure function lineValues (name : string; k : natural; n : positive) return integer_vector is
        variable Line_v : line;
        variable V_v    : integer_vector(0 to n - 1);

        file Txt_f : text;
    begin
        file_open(Txt_f, GoldenDir_g & "/" & name, read_mode);

        for i in 0 to k loop
            readline(Txt_f, Line_v);
        end loop;

        for i in V_v'range loop
            read(Line_v, V_v(i));
        end loop;

        file_close(Txt_f);
        return V_v;
    end function;

    -- Runtime configuration: values of image k (from 0) of the list: driven NX, NY, NZ, absolute and
    -- relative error limit value, then the values taken (CO-RC-07); with the runtime parameters then
    -- the driven parameters (from RtPar_c: user-defined data, M, log2 t_inc, vmin, vmax, Umax, gamma0,
    -- gamma*, K, r) and the parameters taken (from RtPar_c + 10, CO-RP-02)
    constant RtPar_c  : natural  := 10;
    constant RtCols_c : positive := 10 + 20 * toInt(RuntimeParams_g);

    subtype RtLine_t is integer_vector(0 to RtCols_c - 1);

    impure function rtValues (k : natural) return integer_vector is
    begin
        return lineValues(RtList_g & ".txt", k, RtCols_c);
    end function;

    -- Test image, compressed image and number of samples of image img (from 1) of a job
    impure function imageFile (img : positive) return string is
    begin
        if not RuntimeConfig_g then
            return GoldenDir_g & "/image.raw";
        elsif RtList_g /= "runtime" then
            return GoldenDir_g & "/" & RtList_g & "_image_" & twoDigits(img - 1) & ".raw";
        end if;
        return GoldenDir_g & "/image_" & twoDigits(img - 1) & ".raw";
    end function;

    impure function refFile (img : positive) return string is
    begin
        if not RuntimeConfig_g then
            return GoldenDir_g & "/compressed.bin";
        elsif RtList_g /= "runtime" then
            return GoldenDir_g & "/" & RtList_g & "_" & twoDigits(img - 1) & ".bin";
        end if;
        return GoldenDir_g & "/compressed_" & twoDigits(img - 1) & ".bin";
    end function;

    impure function abortFile (img : positive; pos : natural) return string is
    begin
        if RuntimeConfig_g then
            return GoldenDir_g & "/rtabort_" & twoDigits(img - 1) & ".bin";
        end if;
        return GoldenDir_g & "/aborted_" & to_string(pos) & ".bin";
    end function;

    impure function imageSamples (img : positive) return positive is
        variable V_v : RtLine_t;
    begin
        if not RuntimeConfig_g then
            return Samples_c;
        end if;
        V_v := rtValues(img - 1);
        return V_v(5) * V_v(6) * V_v(7);
    end function;

    -- Framing of image i of a job (images beyond the plan are correct)
    function planOf (p : Plan_t; i : positive) return Plan_r is
    begin
        if i > MaxPlan_c then
            return (Normal_c, 0);
        end if;
        return p(i);
    end function;

    signal Clk            : std_logic                                     := '0';
    signal Rst            : std_logic                                     := '1';
    signal In_Valid       : std_logic                                     := '0';
    signal In_Ready       : std_logic;
    signal In_Data        : std_logic_vector(DynamicRange_g - 1 downto 0) := (others => '0');
    signal In_Last        : std_logic                                     := '0';
    signal In_Error       : std_logic                                     := '0';
    signal Lim_Valid      : std_logic                                     := '0';
    signal Lim_Ready      : std_logic;
    signal Lim_Data       : std_logic_vector(15 downto 0)                 := (others => '0');
    signal Out_Valid      : std_logic;
    signal Out_Ready      : std_logic                                     := '0';
    signal Out_Data       : std_logic_vector(OutWidth_g - 1 downto 0);
    signal Out_Keep       : std_logic_vector(OutWidth_g / 8 - 1 downto 0);
    signal Out_Last       : std_logic;
    signal Out_Error      : std_logic;
    signal Ecc_Sec        : std_logic;
    signal Ecc_Ded        : std_logic;
    signal Ev_ImageError  : std_logic;
    signal ErrInj_Channel : std_logic_vector(3 downto 0)                  := (others => '0');
    signal ErrInj_Double  : std_logic                                     := '0';
    signal ErrInj_Valid   : std_logic                                     := '0';
    signal Cfg_XSize      : std_logic_vector(16 downto 0)                 := (others => '0');
    signal Cfg_YSize      : std_logic_vector(16 downto 0)                 := (others => '0');
    signal Cfg_ZSize      : std_logic_vector(16 downto 0)                 := (others => '0');
    signal Cfg_AbsLimit   : std_logic_vector(15 downto 0)                 := (others => '0');
    signal Cfg_RelLimit   : std_logic_vector(15 downto 0)                 := (others => '0');
    signal Cfg_Taken      : std_logic;
    signal Act_XSize      : std_logic_vector(16 downto 0);
    signal Act_YSize      : std_logic_vector(16 downto 0);
    signal Act_ZSize      : std_logic_vector(16 downto 0);
    signal Act_AbsLimit   : std_logic_vector(15 downto 0);
    signal Act_RelLimit   : std_logic_vector(15 downto 0);

    -- Runtime parameters
    signal Cfg_UserData       : std_logic_vector(7 downto 0)  := (others => '0');
    signal Cfg_M              : std_logic_vector(16 downto 0) := (others => '0');
    signal Cfg_WeightInterval : std_logic_vector(3 downto 0)  := (others => '0');
    signal Cfg_WeightVmin     : std_logic_vector(4 downto 0)  := (others => '0');
    signal Cfg_WeightVmax     : std_logic_vector(4 downto 0)  := (others => '0');
    signal Cfg_UnaryLimit     : std_logic_vector(5 downto 0)  := (others => '0');
    signal Cfg_InitCountExp   : std_logic_vector(3 downto 0)  := (others => '0');
    signal Cfg_RescaleSize    : std_logic_vector(3 downto 0)  := (others => '0');
    signal Cfg_AccuInit       : std_logic_vector(3 downto 0)  := (others => '0');
    signal Cfg_RefInterval    : std_logic_vector(12 downto 0) := (others => '0');
    signal Act_UserData       : std_logic_vector(7 downto 0);
    signal Act_M              : std_logic_vector(16 downto 0);
    signal Act_WeightInterval : std_logic_vector(3 downto 0);
    signal Act_WeightVmin     : std_logic_vector(4 downto 0);
    signal Act_WeightVmax     : std_logic_vector(4 downto 0);
    signal Act_UnaryLimit     : std_logic_vector(5 downto 0);
    signal Act_InitCountExp   : std_logic_vector(3 downto 0);
    signal Act_RescaleSize    : std_logic_vector(3 downto 0);
    signal Act_AccuInit       : std_logic_vector(3 downto 0);
    signal Act_RefInterval    : std_logic_vector(12 downto 0);

    -- Runtime configuration: takes of the job (their cycles in StartCyc); timing test (changes of the
    -- configuration inputs around the take)
    signal Takes    : natural := 0;
    signal RtTiming : boolean := false;

    -- Queue test: output held low (QueueTest) until the core holds back a sample for 1000 clock cycles
    -- (QueueRelease); whether that sample was the first of an image (FirstOffer: the source offers the
    -- first sample of an image) and the takes until then
    signal QueueTest    : boolean := false;
    signal QueueRelease : boolean := false;
    signal QueueAtFirst : boolean := false;
    signal QueueTakes   : natural := 0;
    signal FirstOffer   : boolean := false;

    -- Jobs: JobStart counts the started jobs; source and sink report the number of the job they
    -- finished (or that a reset aborted)
    signal JobStart   : natural  := 0;
    signal JobImages  : positive := 1;
    signal JobCompare : boolean  := true;
    signal JobPlan    : Plan_t   := NormalPlan_c;
    signal SrcDone    : natural  := 0;
    signal SinkDone   : natural  := 0;

    -- Image of the job whose In_Last came early (the source of the error limits goes on with the
    -- next image), framing error pulses since the start of the job
    signal AbortImg : natural := 0;
    signal ErrCount : natural := 0;

    -- Throughput: cycles of the first and the last accepted sample of a job, number of samples; cycle of the
    -- first sample of every image
    signal RateFirst  : natural := 0;
    signal RateSecond : natural := 0;
    signal RateLast   : natural := 0;
    signal RateCount  : natural := 0;

    type NatArr_t is array (natural range <>) of natural;

    signal StartCyc : NatArr_t(0 to 127) := (others => 0);

    -- Memory error pulses since the start of the job
    signal SecCount : natural := 0;
    signal DedCount : natural := 0;

    -- Cycles of the last complete job (test_reset)
    signal JobCycles : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_core
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
            UseInLast_g            => UseInLast_g,
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g,
            OutWidth_g             => OutWidth_g
        )
        port map (
            Clk                => Clk,
            Rst                => Rst,
            In_Valid           => In_Valid,
            In_Ready           => In_Ready,
            In_Data            => In_Data,
            In_Last            => In_Last,
            In_Error           => In_Error,
            Lim_Valid          => Lim_Valid,
            Lim_Ready          => Lim_Ready,
            Lim_Data           => Lim_Data,
            Out_Valid          => Out_Valid,
            Out_Ready          => Out_Ready,
            Out_Data           => Out_Data,
            Out_Keep           => Out_Keep,
            Out_Last           => Out_Last,
            Out_Error          => Out_Error,
            Ecc_Sec            => Ecc_Sec,
            Ecc_Ded            => Ecc_Ded,
            Ev_ImageError      => Ev_ImageError,
            ErrInj_Channel     => ErrInj_Channel,
            ErrInj_Double      => ErrInj_Double,
            ErrInj_Valid       => ErrInj_Valid,
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

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
        variable Job_v : natural := 0;

        -- Reset of the DUT for some cycles
        procedure reset is
        begin
            Rst <= '1';

            for i in 1 to 5 loop
                wait until rising_edge(Clk);
            end loop;

            Rst <= '0';
            wait until rising_edge(Clk);
        end procedure;

        -- Starts a job of the source and the sink
        procedure start (images : positive; compare : boolean; plan : Plan_t := NormalPlan_c) is
        begin
            Job_v      := Job_v + 1;
            JobImages  <= images;
            JobCompare <= compare;
            JobPlan    <= plan;
            JobStart   <= Job_v;
            wait until rising_edge(Clk);
        end procedure;

        -- Waits until the sink has finished the current job; a job that does not end within its time
        -- limit fails the test (watchdog)
        procedure waitSink is
        begin
            if SinkDone /= Job_v then
                wait until SinkDone = Job_v for jobTime(JobImages);
                check_value(SinkDone = Job_v, ERROR, "job " & to_string(Job_v) & " ends within its time limit");
            end if;
        end procedure;

        -- Runs a job to its end
        procedure job (images : positive; compare : boolean; plan : Plan_t := NormalPlan_c) is
        begin
            start(images, compare, plan);
            waitSink;
            wait until rising_edge(Clk);
        end procedure;

        -- After the end of a job: no further output
        procedure checkIdle is
        begin

            for i in 0 to 99 loop
                wait until rising_edge(Clk);
                check_value(Out_Valid, '0', ERROR, "no output after the last image");
            end loop;

        end procedure;

        -- Injects an error into the next write of a memory
        procedure inject (channel : natural; double : std_logic) is
        begin
            ErrInj_Channel <= std_logic_vector(to_unsigned(channel, 4));
            ErrInj_Double  <= double;
            ErrInj_Valid   <= '1';
            wait until rising_edge(Clk);
            ErrInj_Valid   <= '0';
        end procedure;

        -- Runtime configuration: one take per image, the first samples in the cycles of the model
        procedure checkTakes (images : natural) is
            constant Starts_c : integer_vector := parseIntVec(ExpStarts_g & ",0");
        begin
            check_value(Takes, images, ERROR, "one configuration take per image");
            if ExpStarts_g /= "" then

                for k in 0 to images - 1 loop
                    check_value(StartCyc(k) - StartCyc(0), Starts_c(Starts_c'low + k), ERROR,
                                "image " & to_string(k) & ": cycle of the first sample (throughput model)");
                end loop;

            end if;
        end procedure;

        variable Channels_v : integer_vector(0 to 15);
        variable NCh_v      : natural;
        variable Wait_v     : natural;
        variable Plan_v     : Plan_t;
        variable Ab_v       : integer_vector(0 to 1);
        constant Starts_c   : integer_vector := parseIntVec(ExpStarts_g & ",0");
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_golden") then
                reset;
                job(Images_g, true);

                -- Throughput
                log(ID_SEQUENCER, "accepted " & to_string(RateCount) & " samples in " &
                    to_string(RateLast - RateFirst + 1) & " cycles");
                if ExpCycles_g > 0 then
                    check_value(RateLast - RateFirst <= ExpCycles_g, ERROR,
                                "cycles between the first and the last sample at most " & to_string(ExpCycles_g));
                end if;
                if ExpPeriod_g > 0 then
                    check_value(RateSecond - RateFirst, ExpPeriod_g, ERROR,
                                "cycles between the first samples of the first two images");
                end if;
                if ExpStarts_g /= "" then

                    for k in 0 to Images_g - 1 loop
                        check_value(StartCyc(k) - StartCyc(0), Starts_c(Starts_c'low + k), ERROR,
                                    "image " & to_string(k) & ": cycle of the first sample (throughput model)");
                    end loop;

                end if;
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                check_value(ErrCount, 0, ERROR, "no framing error");
                checkIdle;

            elsif run("test_ecc") then
                Channels_v := (others => 0);
                NCh_v      := 0;
                if EccChannels_g /= "" then
                    NCh_v                      := parseIntVec(EccChannels_g)'length;
                    Channels_v(0 to NCh_v - 1) := parseIntVec(EccChannels_g);
                end if;

                for i in 0 to NCh_v - 1 loop
                    -- Single bit error: corrected, the compressed image is unchanged
                    reset;
                    inject(Channels_v(i), '0');
                    job(1, true);
                    check_value(SecCount > 0, ERROR, "channel " & to_string(Channels_v(i)) & ": corrected error");
                    check_value(DedCount, 0, ERROR, "channel " & to_string(Channels_v(i)) & ": no double error");

                    -- Double bit error: detected; the compressed image is not compared
                    reset;
                    inject(Channels_v(i), '1');
                    job(1, false);
                    check_value(DedCount > 0, ERROR, "channel " & to_string(Channels_v(i)) & ": detected error");
                end loop;

                -- After a reset the next image is correct
                reset;
                job(1, true);
                check_value(SecCount + DedCount, 0, ERROR, "no memory error after the injections");
                checkIdle;

            elsif run("test_reset") then
                -- Duration of a complete image
                reset;
                job(1, true);

                for i in 1 to Resets_g loop
                    -- Reset at a random time of an image (also in the tail after the last sample)
                    Wait_v := random(0, JobCycles + 20);
                    reset;
                    start(1, true);

                    for c in 1 to Wait_v loop
                        wait until rising_edge(Clk);
                    end loop;

                    log(ID_SEQUENCER, "reset after " & to_string(Wait_v) & " of " & to_string(JobCycles) & " cycles");

                    -- The next image is correct
                    reset;
                    waitSink;
                    job(1, true);
                end loop;

                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                checkIdle;

            elsif run("test_framing") then
                -- Errors between correct images, all images back to back: In_Last on the first sample,
                -- in the middle of the image, on the last sample but one and at a seeded sample (the
                -- positions of the aborted images of tb/golden, AbortPos_g); In_Last missing, then a
                -- random number of samples up to the next In_Last or only one
                Plan_v     := NormalPlan_c;
                Plan_v(2)  := (Early_c,
                               abortPos(0));
                Plan_v(4)  := (Early_c,
                               abortPos(1));
                Plan_v(5)  := (Early_c,
                               abortPos(2));
                Plan_v(7)  := (Missing_c,
                               random(1,
                                         Samples_c));
                Plan_v(8)  := (Missing_c,
                               1);
                Plan_v(10) := (Early_c,
                               abortPos(3));
                reset;
                job(11, true, Plan_v);
                check_value(ErrCount, 6, ERROR, "one framing error event per image with an error");
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");

                -- Aborted images back to back at every position of AbortPos_g, then a correct image
                Plan_v := NormalPlan_c;

                for i in 1 to abortCount loop
                    Plan_v(i) := (Early_c,
                                  abortPos(i - 1));
                end loop;

                reset;
                job(abortCount + 1, true, Plan_v);
                check_value(ErrCount, abortCount, ERROR, "one framing error event per aborted image");

                -- In_Error (CO-FR-08) between correct images: with In_Last on the last sample, with
                -- an early In_Last, without In_Last, on the samples discarded after a missing In_Last
                Plan_v    := NormalPlan_c;
                Plan_v(2) := (Flagged_c,
                              0);
                Plan_v(4) := (EarlyErr_c,
                              abortPos(random(0,
                                                 3)));
                Plan_v(5) := (StrayErr_c,
                              random(0,
                                        maximum(Samples_c - 2,
                                                   0)));
                Plan_v(6) := (Flagged_c,
                              0);
                Plan_v(7) := (MissingErr_c,
                              random(1,
                                        Samples_c));
                reset;
                job(8, true, Plan_v);
                check_value(ErrCount, 4, ERROR, "one framing error event per image ended with an error");
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");

                -- An image with an error, a reset at a random time of the abort or of the discarded
                -- samples, then a correct image
                Plan_v := NormalPlan_c;
                reset;
                job(1, true);

                for i in 1 to Resets_g loop
                    if i mod 2 = 1 then
                        Plan_v(1) := (Early_c,
                                      abortPos(random(0,
                                                         3)));
                    else
                        Plan_v(1) := (Missing_c,
                                      random(1,
                                                Samples_c));
                    end if;
                    Wait_v := random(0, 2 * JobCycles + 20);
                    reset;
                    start(2, true, Plan_v);

                    for c in 1 to Wait_v loop
                        wait until rising_edge(Clk);
                    end loop;

                    log(ID_SEQUENCER, "reset after " & to_string(Wait_v) & " cycles");
                    reset;
                    waitSink;
                    job(1, true);
                    check_value(ErrCount, 0, ERROR, "no framing error after the reset");
                end loop;

                -- In_Last on the first sample of an image that follows a correct image back to back, a
                -- reset with the error event, then a correct image
                Plan_v    := NormalPlan_c;
                Plan_v(2) := (Early_c,
                              0);
                reset;
                start(2, true, Plan_v);
                wait until rising_edge(Clk) and Ev_ImageError = '1';
                reset;
                waitSink;
                job(1, true);
                check_value(ErrCount, 0, ERROR, "no framing error after the reset");

                checkIdle;

            elsif run("test_runtime") or run("test_runtime_range") then
                reset;
                job(RtImages_g, true);
                checkTakes(RtImages_g);
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                check_value(ErrCount, 0, ERROR, "no framing error");
                checkIdle;

            elsif run("test_runtime_queue") then
                -- The output stays low until the core holds back a sample for 1000 cycles (p_queue)
                reset;
                QueueTest <= true;
                job(RtImages_g, true);
                checkTakes(RtImages_g);
                check_value(QueueRelease, ERROR, "the core held back a sample while the output was low");
                check_value(QueueAtFirst, ERROR, "the sample held back was the first sample of an image");
                check_value(QueueTakes >= 16, ERROR, "at least 16 images taken before the stall (" &
                            to_string(QueueTakes) & ")");
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                check_value(ErrCount, 0, ERROR, "no framing error");
                checkIdle;

            elsif run("test_runtime_timing") then
                -- The configuration inputs change around the take (source, RtTiming); with the image
                -- framing the images of rtabort.txt end early and two images miss In_Last
                RtTiming <= true;
                Plan_v   := NormalPlan_c;
                if UseInLast_g then
                    Ab_v                := lineValues("rtabort.txt", 0, 2);
                    Plan_v(Ab_v(0) + 1) := (Early_c,
                                            Ab_v(1));
                    Ab_v                := lineValues("rtabort.txt", 1, 2);
                    Plan_v(Ab_v(0) + 1) := (Early_c,
                                            Ab_v(1));
                    Plan_v(4)           := (Missing_c,
                                            5);
                    Plan_v(11)          := (Missing_c,
                                            1);
                end if;
                reset;
                job(RtImages_g, true, Plan_v);
                checkTakes(RtImages_g);
                check_value(ErrCount, 4 * toInt(UseInLast_g), ERROR, "one framing error event per image with an error");
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                checkIdle;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Image samples (little-endian 8, 16 or 32-bit containers), JobImages times per job, with the
    -- image end marker of the job plan (random without UseInLast_g)
    p_source : process is
        variable Abort_v : boolean;
        variable Wait_v  : natural;
        variable N_v     : positive;
        variable V_v     : RtLine_t;
        variable Mode_v  : natural;
        variable Next_v  : RtLine_t;

        -- Configuration inputs: values driven for image k of the list (or the values that follow
        -- after the last image)
        procedure drive (k : natural) is
            variable D_v : RtLine_t;
        begin
            if k < RtImages_g then
                D_v := rtValues(k);
            else
                D_v := rtValues(0);
            end if;
            Cfg_XSize    <= std_logic_vector(to_unsigned(D_v(0), 17));
            Cfg_YSize    <= std_logic_vector(to_unsigned(D_v(1), 17));
            Cfg_ZSize    <= std_logic_vector(to_unsigned(D_v(2), 17));
            Cfg_AbsLimit <= std_logic_vector(to_unsigned(D_v(3), 16));
            Cfg_RelLimit <= std_logic_vector(to_unsigned(D_v(4), 16));
            if RuntimeParams_g then
                Cfg_UserData       <= std_logic_vector(to_unsigned(D_v(RtPar_c), 8));
                Cfg_M              <= std_logic_vector(to_unsigned(D_v(RtPar_c + 1), 17));
                Cfg_WeightInterval <= std_logic_vector(to_unsigned(D_v(RtPar_c + 2), 4));
                Cfg_WeightVmin     <= std_logic_vector(to_signed(D_v(RtPar_c + 3), 5));
                Cfg_WeightVmax     <= std_logic_vector(to_signed(D_v(RtPar_c + 4), 5));
                Cfg_UnaryLimit     <= std_logic_vector(to_unsigned(D_v(RtPar_c + 5), 6));
                Cfg_InitCountExp   <= std_logic_vector(to_unsigned(D_v(RtPar_c + 6), 4));
                Cfg_RescaleSize    <= std_logic_vector(to_unsigned(D_v(RtPar_c + 7), 4));
                Cfg_AccuInit       <= std_logic_vector(to_unsigned(D_v(RtPar_c + 8), 4));
                Cfg_RefInterval    <= std_logic_vector(to_unsigned(D_v(RtPar_c + 9), 13));
            end if;
        end procedure;

        -- One sample (Wait_v: cycles until it is taken); a reset aborts the job
        procedure send (data : std_logic_vector; last : std_logic; err : std_logic) is
        begin

            while random(0, 99) < InGapPct_g and Rst = '0' loop
                wait until rising_edge(Clk);
            end loop;

            In_Valid <= '1';
            In_Data  <= data;
            In_Last  <= last;
            In_Error <= err;
            Wait_v   := 0;

            loop
                wait until rising_edge(Clk);
                exit when In_Ready = '1' or Rst = '1';
                Wait_v := Wait_v + 1;
            end loop;

            In_Valid <= '0';
            In_Last  <= '0';
            In_Error <= '0';
            Abort_v  := Rst = '1';
        end procedure;

        variable Byte_v : natural;
        variable Eof_v  : boolean;
        variable Smp_v  : std_logic_vector(31 downto 0);
        variable Plan_v : Plan_r;
        variable Idx_v  : natural;
        variable Last_v : std_logic;
        variable Err_v  : std_logic;

        file Img_f : ByteFile_t;
    begin
        wait on JobStart;
        Abort_v  := false;
        AbortImg <= 0;

        for img in 1 to JobImages loop
            Plan_v := planOf(JobPlan, img);
            Idx_v  := 0;
            N_v    := imageSamples(img);
            file_open(Img_f, imageFile(img), read_mode);
            -- Runtime configuration: the values of the image on the configuration inputs; in the timing
            -- test two cycles before the first sample (modes 0 and 2) or in the cycle in which the
            -- core accepts it (mode 1)
            Mode_v := 0;
            if RuntimeConfig_g then
                if RtTiming then
                    Mode_v := (img - 1) mod 3;
                end if;
                if Mode_v /= 1 then
                    drive(img - 1);
                    if RtTiming then
                        wait until rising_edge(Clk);
                        wait until rising_edge(Clk);
                    end if;
                end if;
            end if;

            loop
                Smp_v := (others => '0');

                for b in 0 to Bytes_c - 1 loop
                    readByte(Img_f, Byte_v, Eof_v);
                    Smp_v(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(Byte_v, 8));
                end loop;

                exit when Eof_v;

                if UseInLast_g then
                    Last_v := toSl((isComplete(Plan_v.Kind) and Idx_v = N_v - 1) or
                                   (isEarly(Plan_v.Kind) and Idx_v = Plan_v.Pos));
                    Err_v  := toSl((Plan_v.Kind = Flagged_c and Idx_v = N_v - 1) or
                                   ((Plan_v.Kind = EarlyErr_c or Plan_v.Kind = StrayErr_c) and Idx_v = Plan_v.Pos));
                else
                    Last_v := toSl(random(0, 1) = 1);
                    Err_v  := Last_v;
                end if;
                -- Timing test, mode 1: the values change in the cycle in which the first sample is accepted
                if Idx_v = 0 and Mode_v = 1 then

                    loop
                        wait until rising_edge(Clk);
                        exit when In_Ready = '1' or Rst = '1';
                    end loop;

                    drive(img - 1);
                end if;
                FirstOffer <= Idx_v = 0;
                send(Smp_v(DynamicRange_g - 1 downto 0), Last_v, Err_v);
                exit when Abort_v;
                -- Runtime configuration: the core takes the configuration with the first sample only; then
                -- the inputs carry other values (the next image), at once (mode 1), two cycles later (mode 0)
                -- or in the middle of the image (mode 2)
                if RuntimeConfig_g then
                    check_value(Cfg_Taken, toSl(Idx_v = 0), ERROR, "image " & to_string(img) & " sample " &
                                to_string(Idx_v) & ": configuration taken with the first sample only");
                    if (Idx_v = 0 and Mode_v = 1) or (Idx_v = 0 and Mode_v = 0 and not RtTiming) then
                        drive(img);
                    elsif Idx_v = 0 and Mode_v = 0 then
                        wait until rising_edge(Clk);
                        wait until rising_edge(Clk);
                        drive(img);
                    elsif Idx_v = N_v / 2 and Mode_v = 2 then
                        drive(img);
                    end if;
                end if;

                -- In_Last early: the rest of the image is lost
                if isEarly(Plan_v.Kind) and Idx_v = Plan_v.Pos then
                    AbortImg <= img;
                    exit;
                end if;
                Idx_v := Idx_v + 1;
            end loop;

            file_close(Img_f);
            exit when Abort_v;

            -- In_Last missing: further samples up to the next In_Last, discarded at once (without a take)
            if Plan_v.Kind = Missing_c or Plan_v.Kind = MissingErr_c then

                for i in 1 to Plan_v.Pos loop
                    send(std_logic_vector(to_unsigned(random(0, 2 ** minimum(DynamicRange_g, 8) - 1), DynamicRange_g)),
                         toSl(i = Plan_v.Pos), toSl(Plan_v.Kind = MissingErr_c));
                    exit when Abort_v;
                    check_value(Wait_v, 0, ERROR, "image " & to_string(img) & ": discarded sample taken at once");
                end loop;

                exit when Abort_v;
            end if;
        end loop;

        SrcDone <= JobStart;
    end process;

    -- Queue test: a sample held back for 1000 clock cycles while the output is low releases the output; the
    -- configuration queue is full when this sample is the first of an image. The limit is above every wait of
    -- a sample for the samples it depends on (issue distances up to 255 cycles plus the image start)
    p_queue : process is
        constant Limit_c : positive := 1000;
        variable Cnt_v   : natural  := 0;
    begin
        wait until rising_edge(Clk);
        if QueueTest and not QueueRelease and In_Valid = '1' and In_Ready = '0' then
            Cnt_v := Cnt_v + 1;
        else
            Cnt_v := 0;
        end if;
        if Cnt_v = Limit_c then
            QueueAtFirst <= FirstOffer;
            QueueTakes   <= Takes;
            QueueRelease <= true;
            log(ID_SEQUENCER, "queue test: output released after " & to_string(Takes) &
                              " takes, sample held back is the first of an image: " & to_string(FirstOffer), "p_queue");
        end if;
    end process;

    -- Throughput: cycle of the first and the last accepted sample of a job and of the first sample of the
    -- second image
    p_rate : process is
        variable Cycle_v : natural := 0;
        variable Count_v : natural := 0;
        variable Job_v   : natural := 0;
        variable Takes_v : natural := 0;
        variable V_v     : RtLine_t;
        variable T_v     : natural;

        -- An Act_ output of a runtime parameter against the value taken (two's complement for vmin and vmax)
        procedure checkAct (act : std_logic_vector; idx : natural; name : string; sgn : boolean := false) is
        begin
            if sgn then
                check_value(to_integer(signed(act)), V_v(T_v + idx), ERROR,
                            "image " & to_string(Takes_v) & ": " & name);
            else
                check_value(to_integer(unsigned(act)), V_v(T_v + idx), ERROR,
                            "image " & to_string(Takes_v) & ": " & name);
            end if;
        end procedure;

        variable Chk_v : boolean := false;
    begin
        wait until rising_edge(Clk);
        if JobStart /= Job_v then
            Job_v     := JobStart;
            Count_v   := 0;
            RateCount <= 0;
            Takes_v   := 0;
            Takes     <= 0;
        end if;
        -- Runtime configuration: the Act_ outputs show the values taken from the cycle after the take
        if Chk_v then
            check_value(to_integer(unsigned(Act_XSize)), V_v(5), ERROR, "image " & to_string(Takes_v) & ": Act_XSize");
            check_value(to_integer(unsigned(Act_YSize)), V_v(6), ERROR, "image " & to_string(Takes_v) & ": Act_YSize");
            check_value(to_integer(unsigned(Act_ZSize)), V_v(7), ERROR, "image " & to_string(Takes_v) & ": Act_ZSize");
            check_value(to_integer(unsigned(Act_AbsLimit)), V_v(8), ERROR,
                        "image " & to_string(Takes_v) & ": Act_AbsLimit");
            check_value(to_integer(unsigned(Act_RelLimit)), V_v(9), ERROR,
                        "image " & to_string(Takes_v) & ": Act_RelLimit");
            -- Runtime parameters: the values taken (CO-RP-03)
            if RuntimeParams_g then
                T_v := RtPar_c + 10;
                checkAct(Act_UserData, 0, "Act_UserData");
                checkAct(Act_M, 1, "Act_M");
                checkAct(Act_WeightInterval, 2, "Act_WeightInterval");
                checkAct(Act_WeightVmin, 3, "Act_WeightVmin", true);
                checkAct(Act_WeightVmax, 4, "Act_WeightVmax", true);
                checkAct(Act_UnaryLimit, 5, "Act_UnaryLimit");
                checkAct(Act_InitCountExp, 6, "Act_InitCountExp");
                checkAct(Act_RescaleSize, 7, "Act_RescaleSize");
                checkAct(Act_AccuInit, 8, "Act_AccuInit");
                checkAct(Act_RefInterval, 9, "Act_RefInterval");
            end if;
            Chk_v := false;
        end if;
        if RuntimeConfig_g and Cfg_Taken = '1' and Rst = '0' then
            if Takes_v < RtImages_g then
                V_v := rtValues(Takes_v);
            end if;
            StartCyc(Takes_v) <= Cycle_v;
            Takes_v           := Takes_v + 1;
            Takes             <= Takes_v;
            Chk_v             := true;
        end if;
        if In_Valid = '1' and In_Ready = '1' then
            if Count_v = 0 then
                RateFirst <= Cycle_v;
            end if;
            if not RuntimeConfig_g and Count_v mod Samples_c = 0 and Count_v / Samples_c <= StartCyc'high then
                StartCyc(Count_v / Samples_c) <= Cycle_v;
                log(ID_SEQUENCER, "image " & to_string(Count_v / Samples_c) & ": first sample in cycle " &
                    to_string(Cycle_v));
            end if;
            if Count_v = Samples_c then
                RateSecond <= Cycle_v;
            end if;
            RateLast  <= Cycle_v;
            Count_v   := Count_v + 1;
            RateCount <= Count_v;
        end if;
        Cycle_v := Cycle_v + 1;
    end process;

    -- Watchdog: while a job runs, a sample, an error limit value or a word is transferred at least every
    -- WatchdogCycles_c clock cycles (a hang fails the test instead of running without end)
    p_watchdog : process is
        constant WatchdogCycles_c : positive := 20000;
        variable Idle_v           : natural  := 0;
    begin
        wait until rising_edge(Clk);
        if Rst = '1' or SinkDone = JobStart or (In_Valid = '1' and In_Ready = '1') or
           (Lim_Valid = '1' and Lim_Ready = '1') or (Out_Valid = '1' and Out_Ready = '1') then
            Idle_v := 0;
        else
            Idle_v := Idle_v + 1;
            if Idle_v = WatchdogCycles_c then
                alert(ERROR, "no transfer for " & to_string(WatchdogCycles_c) & " clock cycles while job " &
                      to_string(JobStart) & " runs");
            end if;
        end if;
    end process;

    -- Memory error and framing error pulses since the start of the job, cycles of the job
    p_ecc : process is
        variable Job_v    : natural := 0;
        variable Cycles_v : natural := 0;
    begin
        wait until rising_edge(Clk);
        if JobStart /= Job_v then
            Job_v    := JobStart;
            SecCount <= 0;
            DedCount <= 0;
            ErrCount <= 0;
            Cycles_v := 0;
        else
            if Ecc_Sec = '1' then
                SecCount <= SecCount + 1;
            end if;
            if Ecc_Ded = '1' then
                DedCount <= DedCount + 1;
            end if;
            if Ev_ImageError = '1' then
                ErrCount <= ErrCount + 1;
            end if;
            Cycles_v := Cycles_v + 1;
            if SinkDone /= Job_v then
                JobCycles <= Cycles_v;
            end if;
        end if;
    end process;

    -- Periodic error limit values (16-bit big-endian), JobImages times per job; after an early In_Last
    -- the remaining values of that image are dropped (the core takes none of them)
    p_limits : process is
        variable Hi_v    : natural;
        variable Lo_v    : natural;
        variable Eof_v   : boolean;
        variable Abort_v : boolean;

        file Lim_f : ByteFile_t;
    begin
        if not Periodic_c then
            wait;
        end if;
        wait on JobStart;
        Abort_v := false;

        for img in 1 to JobImages loop
            file_open(Lim_f, GoldenDir_g & "/error_limits.bin", read_mode);

            loop
                readByte(Lim_f, Hi_v, Eof_v);
                readByte(Lim_f, Lo_v, Eof_v);
                exit when Eof_v;
                Lim_Valid <= '1';
                Lim_Data  <= std_logic_vector(to_unsigned(Hi_v * 256 + Lo_v, 16));
                wait until rising_edge(Clk) and (Lim_Ready = '1' or Rst = '1' or AbortImg = img);
                Lim_Valid <= '0';
                Abort_v   := Rst = '1';
                exit when Abort_v or (AbortImg = img and Lim_Ready = '0');
            end loop;

            file_close(Lim_f);
            exit when Abort_v;
        end loop;

    end process;

    -- Compressed image of the CNES reference software: the valid bytes of every word, byte n in
    -- Out_Data(8n + 7 downto 8n) (first byte in bits 7:0), valid bytes contiguous from byte 0 and
    -- all bytes valid except in the last word of an image, which carries the last flag. Out_Error
    -- only on the last word of an image with a framing error. An aborted image (In_Last early) is a
    -- prefix of the compressed image with at least the header, then zero fill bits up to a multiple
    -- of the output word size. A job without comparison only waits for the last word of every image.
    p_sink : process is
        variable Exp_v   : natural;
        variable Eof_v   : boolean;
        variable Cnt_v   : natural;
        variable Gap_v   : boolean;
        variable Abort_v : boolean;
        variable Plan_v  : Plan_r;
        variable Byte_v  : natural;

        file Ref_f : ByteFile_t;
    begin
        wait on JobStart;
        Abort_v := false;

        for img in 1 to JobImages loop
            Plan_v := planOf(JobPlan, img);
            -- An aborted image is the compressed image of the samples taken (reference model)
            if isEarly(Plan_v.Kind) then
                file_open(Ref_f, abortFile(img, Plan_v.Pos), read_mode);
            else
                file_open(Ref_f, refFile(img), read_mode);
            end if;
            Cnt_v := 0;
            readByte(Ref_f, Exp_v, Eof_v);

            loop

                -- Queue test: no word is taken until the core holds back a sample (with QueueHoldBytes_g from that
                -- byte of the first image on)
                while QueueTest and not QueueRelease and Rst = '0' and (img > 1 or Cnt_v >= QueueHoldBytes_g) loop
                    Out_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                while random(0, 99) < OutStallPct_g and Rst = '0' loop
                    Out_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                Out_Ready <= '1';
                wait until rising_edge(Clk) and (Out_Valid = '1' or Rst = '1');
                Out_Ready <= '0';
                Abort_v   := Rst = '1';
                exit when Abort_v;

                if Out_Last = '0' then
                    check_value(Out_Error, '0', ERROR,
                                "image " & to_string(img) & " byte " & to_string(Cnt_v) & ": no error flag");
                end if;

                if JobCompare then
                    Gap_v := false;

                    for b in 0 to OutWidth_g / 8 - 1 loop
                        if Out_Keep(b) = '1' then
                            check_value(not Gap_v, ERROR,
                                        "image " & to_string(img) & " byte " & to_string(Cnt_v) &
                                        ": valid bytes contiguous from byte 0");
                            check_value(not Eof_v, ERROR, "image " & to_string(img) & ": no byte beyond the end");
                            Byte_v := to_integer(unsigned(Out_Data(8 * b + 7 downto 8 * b)));
                            check_value(Byte_v, Exp_v, ERROR, "image " & to_string(img) & " byte " & to_string(Cnt_v));
                            Cnt_v  := Cnt_v + 1;
                            readByte(Ref_f, Exp_v, Eof_v);
                        else
                            check_value(Out_Last, '1', ERROR,
                                        "image " & to_string(img) & " byte " & to_string(Cnt_v) &
                                        ": all bytes valid except in the last word");
                            Gap_v := true;
                        end if;
                    end loop;

                    check_value(Out_Last, toSl(Eof_v), ERROR,
                                "image " & to_string(img) & " byte " & to_string(Cnt_v) & ": last flag");
                end if;

                exit when Out_Last = '1';
            end loop;

            file_close(Ref_f);
            exit when Abort_v;

            -- Error flag on the last word; size and header of an aborted image
            check_value(Out_Error, toSl(UseInLast_g and isFaulty(Plan_v.Kind)), ERROR,
                        "image " & to_string(img) & ": error flag on the last word");
            if JobCompare and MaxBytes_g > 0 then
                check_value(Cnt_v <= MaxBytes_g, ERROR,
                            "image " & to_string(img) & ": " & to_string(Cnt_v) & " bytes, at most " &
                            to_string(MaxBytes_g));
            end if;
            if JobCompare and isEarly(Plan_v.Kind) then
                check_value(Cnt_v >= HeaderBytes_g, ERROR, "image " & to_string(img) & ": complete header");
                log(ID_SEQUENCER, "image " & to_string(img) & ": aborted after sample " & to_string(Plan_v.Pos) &
                    ", equal to the compressed image of the samples taken");
            end if;
            log(ID_SEQUENCER, "image " & to_string(img) & ": " & to_string(Cnt_v) & " bytes checked");
        end loop;

        SinkDone <= JobStart;
    end process;

end architecture;
