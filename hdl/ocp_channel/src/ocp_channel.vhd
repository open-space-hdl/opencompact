---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- OpenCompact compression channel: SDUs of samples in (ocp_input_adapter), compression with
-- ocp_core and its image framing, every compressed image out as one packet of a byte stream, and
-- the status registers (ocp_mib) on an AXI4-Lite slave.
--
-- Documentation: hdl/ocp_channel/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;

library work;
    use work.ocp_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_channel is
    generic (
        -- Image (CCSDS 3, 5.3.2)
        XSize_g                : positive range 1 to 65536                  := 8;
        YSize_g                : positive range 1 to 65536                  := 8;
        ZSize_g                : positive range 1 to 65536                  := 4;
        DynamicRange_g         : positive range 2 to 32                     := 16;
        SignedSamples_g        : boolean                                    := false;
        UserData_g             : natural range 0 to 255                     := 0;
        EncodingOrder_g        : string                                     := "BI";
        SubFrameDepth_g        : positive range 1 to 65536                  := 4;
        OutputWordSize_g       : positive range 1 to 8                      := 1;
        EntropyCoder_g         : string                                     := "SAMPLE_ADAPTIVE";
        SupTableCount_g        : natural range 0 to 15                      := 0;
        SupTableData_g         : std_logic_vector                           := x"00";
        -- Predictor (CCSDS 4)
        PredictionBands_g      : natural range 0 to 15                      := 3;
        PredictionMode_g       : string                                     := "FULL";
        LocalSum_g             : string                                     := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive range 32 to 64                    := 64;
        WeightResolution_g     : positive range 4 to 19                     := 13;
        WeightUpdateInterval_g : positive range 4 to 11                     := 6;
        WeightUpdateVmin_g     : integer range -6 to 9                      := -1;
        WeightUpdateVmax_g     : integer range -6 to 9                      := 3;
        WeightExpOffsetsUsed_g : boolean                                    := false;
        WeightExpOffsetTable_g : boolean                                    := false;
        WeightExpOffsets_g     : integer_vector                             := (0 => 0);
        CustomWeights_g        : boolean                                    := false;
        WeightInitTable_g      : boolean                                    := false;
        WeightInitResolution_g : natural range 0 to 22                      := 0;
        WeightInitValues_g     : integer_vector                             := (0 => 0);
        -- Quantizer (CCSDS 4.8)
        Fidelity_g             : string                                     := "LOSSLESS";
        PeriodicUpdate_g       : boolean                                    := false;
        UpdatePeriodExp_g      : natural range 0 to 9                       := 0;
        AbsBandDependent_g     : boolean                                    := false;
        AbsBitDepth_g          : positive range 1 to 16                     := 1;
        AbsErrorLimits_g       : integer_vector                             := (0 => 0);
        RelBandDependent_g     : boolean                                    := false;
        RelBitDepth_g          : positive range 1 to 16                     := 1;
        RelErrorLimits_g       : integer_vector                             := (0 => 0);
        -- Sample representatives (CCSDS 4.9)
        SampleRepResolution_g  : natural range 0 to 4                       := 0;
        DampingBandVarying_g   : boolean                                    := false;
        DampingTable_g         : boolean                                    := false;
        Damping_g              : integer_vector                             := (0 => 0);
        OffsetBandVarying_g    : boolean                                    := false;
        OffsetTable_g          : boolean                                    := false;
        Offset_g               : integer_vector                             := (0 => 0);
        -- Sample-adaptive and hybrid entropy coder (CCSDS 5.4.3.2, 5.4.3.3)
        UnaryLimit_g           : positive range 8 to 32                     := 16;
        RescaleCounterSize_g   : positive range 4 to 11                     := 6;
        InitialCountExp_g      : positive range 1 to 8                      := 1;
        AccuInitBandVarying_g  : boolean                                    := false;
        AccuInitTable_g        : boolean                                    := false;
        AccuInit_g             : integer_vector                             := (0 => 3);
        HybridAccuInit_g       : integer_vector                             := (0 => 0);
        HybridAccuInitHigh_g   : integer_vector                             := (0 => 0);
        -- Block-adaptive entropy coder (CCSDS 5.4.3.4)
        BlockSize_g            : positive                                   := 16;
        RestrictedCodes_g      : boolean                                    := false;
        RefInterval_g          : positive range 1 to 4096                   := 4096;
        -- Implementation of ocp_core: width of its words in bits (8, 16, 32 or 64), speculative weight
        -- loop of the predictor, memory style
        OutWidth_g             : positive                                   := 8;
        Speculation_g          : boolean                                    := true;
        RamStyle_g             : string                                     := "auto";
        -- Runtime configuration of the image dimensions and error limit values over the AXI4-Lite port
        -- (ocp_mib, register map section "Runtime configuration"); XSize_g, YSize_g and ZSize_g are the
        -- maxima
        RuntimeConfig_g        : boolean                                    := false;
        -- Runtime parameters (with RuntimeConfig_g): user-defined data, M, the weight update and the entropy
        -- coder parameters over the AXI4-Lite port (register map, NEXT_SAMPLES to NEXT_BLOCK)
        RuntimeParams_g        : boolean                                    := false;
        -- Streams: SDU stream and compressed image stream in bits (8, 16, 32, 64 or 128)
        InStreamWidth_g        : positive                                   := 128;
        OutStreamWidth_g       : positive                                   := 128;
        -- User signal of the SDU stream: end mark (In_User and UserLastMask_g) = UserLastValue_g,
        -- faulty SDU (In_User and UserErrorMask_g) /= 0
        UserWidth_g            : positive range 1 to 64                     := 1;
        UserLastMask_g         : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0');
        UserLastValue_g        : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0');
        UserErrorMask_g        : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0')
    );
    port (
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- SDU stream: big-endian sample containers of ceil(D/8) bytes, a whole number per SDU; byte n of
        -- a beat in In_Data(8n + 7 downto 8n); all bytes valid except in the last beat of an SDU
        In_Valid          : in    std_logic;
        In_Ready          : out   std_logic;
        In_Data           : in    std_logic_vector(InStreamWidth_g - 1 downto 0);
        In_Keep           : in    std_logic_vector(InStreamWidth_g / 8 - 1 downto 0);
        In_Last           : in    std_logic;
        In_User           : in    std_logic_vector(UserWidth_g - 1 downto 0);
        -- Error limit values for periodic error limit updating
        Lim_Valid         : in    std_logic                     := '0';
        Lim_Ready         : out   std_logic;
        Lim_Data          : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Compressed images, one packet per image: byte n of a beat in Out_Data(8n + 7 downto 8n), the
        -- first byte of the image in bits 7:0; all bytes valid except in the last beat, contiguous from
        -- byte 0; Out_Error with Out_Last for an image with an error
        Out_Valid         : out   std_logic;
        Out_Ready         : in    std_logic;
        Out_Data          : out   std_logic_vector(OutStreamWidth_g - 1 downto 0);
        Out_Keep          : out   std_logic_vector(OutStreamWidth_g / 8 - 1 downto 0);
        Out_Last          : out   std_logic;
        Out_Error         : out   std_logic;
        -- Status registers
        S_AxiLite_ArAddr  : in    std_logic_vector(7 downto 0);
        S_AxiLite_ArValid : in    std_logic;
        S_AxiLite_ArReady : out   std_logic;
        S_AxiLite_AwAddr  : in    std_logic_vector(7 downto 0);
        S_AxiLite_AwValid : in    std_logic;
        S_AxiLite_AwReady : out   std_logic;
        S_AxiLite_WData   : in    std_logic_vector(31 downto 0);
        S_AxiLite_WStrb   : in    std_logic_vector(3 downto 0);
        S_AxiLite_WValid  : in    std_logic;
        S_AxiLite_WReady  : out   std_logic;
        S_AxiLite_BResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_BValid  : out   std_logic;
        S_AxiLite_BReady  : in    std_logic;
        S_AxiLite_RData   : out   std_logic_vector(31 downto 0);
        S_AxiLite_RResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_RValid  : out   std_logic;
        S_AxiLite_RReady  : in    std_logic;
        -- Memory errors of ocp_core (pulses), framing error of an image (pulse)
        Ecc_Sec           : out   std_logic;
        Ecc_Ded           : out   std_logic;
        Ev_ImageError     : out   std_logic;
        -- Error injection into the memories of ocp_core
        ErrInj_Channel    : in    std_logic_vector(3 downto 0)  := (others => '0');
        ErrInj_Double     : in    std_logic                     := '0';
        ErrInj_Valid      : in    std_logic                     := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_channel is

    -- Samples to the core
    signal SmpValid : std_logic;
    signal SmpReady : std_logic;
    signal SmpData  : std_logic_vector(DynamicRange_g - 1 downto 0);
    signal SmpLast  : std_logic;
    signal SmpError : std_logic;

    -- Words of the core
    signal WordValid : std_logic;
    signal WordReady : std_logic;
    signal WordData  : std_logic_vector(OutWidth_g - 1 downto 0);
    signal WordKeep  : std_logic_vector(OutWidth_g / 8 - 1 downto 0);
    signal WordLast  : std_logic;
    signal WordError : std_logic;

    -- Events
    signal EvSduError     : std_logic;
    signal EvSduDiscarded : std_logic;
    signal EvImageDone    : std_logic;
    signal EvImageAborted : std_logic;
    signal EccSec         : std_logic;
    signal EccDed         : std_logic;

    -- Error flag of the image whose last word is in the output converter, last beat of the converter
    signal ErrFlag  : std_logic;
    signal ConvLast : std_logic;

    -- Runtime configuration: committed configuration of the MIB, take of the core, values the core took
    signal CfgXSize          : std_logic_vector(16 downto 0);
    signal CfgYSize          : std_logic_vector(16 downto 0);
    signal CfgZSize          : std_logic_vector(16 downto 0);
    signal CfgAbsLimit       : std_logic_vector(15 downto 0);
    signal CfgRelLimit       : std_logic_vector(15 downto 0);
    signal CfgTaken          : std_logic;
    signal ActXSize          : std_logic_vector(16 downto 0);
    signal ActYSize          : std_logic_vector(16 downto 0);
    signal ActZSize          : std_logic_vector(16 downto 0);
    signal ActAbsLimit       : std_logic_vector(15 downto 0);
    signal ActRelLimit       : std_logic_vector(15 downto 0);
    -- Runtime parameters: committed by the MIB, taken by the core
    signal CfgUserData       : std_logic_vector(7 downto 0);
    signal CfgM              : std_logic_vector(16 downto 0);
    signal CfgWeightInterval : std_logic_vector(3 downto 0);
    signal CfgWeightVmin     : std_logic_vector(4 downto 0);
    signal CfgWeightVmax     : std_logic_vector(4 downto 0);
    signal CfgUnaryLimit     : std_logic_vector(5 downto 0);
    signal CfgInitCountExp   : std_logic_vector(3 downto 0);
    signal CfgRescaleSize    : std_logic_vector(3 downto 0);
    signal CfgAccuInit       : std_logic_vector(3 downto 0);
    signal CfgRefInterval    : std_logic_vector(12 downto 0);
    signal ActUserData       : std_logic_vector(7 downto 0);
    signal ActM              : std_logic_vector(16 downto 0);
    signal ActWeightInterval : std_logic_vector(3 downto 0);
    signal ActWeightVmin     : std_logic_vector(4 downto 0);
    signal ActWeightVmax     : std_logic_vector(4 downto 0);
    signal ActUnaryLimit     : std_logic_vector(5 downto 0);
    signal ActInitCountExp   : std_logic_vector(3 downto 0);
    signal ActRescaleSize    : std_logic_vector(3 downto 0);
    signal ActAccuInit       : std_logic_vector(3 downto 0);
    signal ActRefInterval    : std_logic_vector(12 downto 0);

begin

    assert OutStreamWidth_g = 8 or OutStreamWidth_g = 16 or OutStreamWidth_g = 32 or OutStreamWidth_g = 64 or
           OutStreamWidth_g = 128
        report "ocp_channel: OutStreamWidth_g must be 8, 16, 32, 64 or 128"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Input adapter
    -----------------------------------------------------------------------------------------------
    i_input : entity work.ocp_input_adapter
        generic map (
            InWidth_g       => InStreamWidth_g,
            DynamicRange_g  => DynamicRange_g,
            UserWidth_g     => UserWidth_g,
            UserLastMask_g  => UserLastMask_g,
            UserLastValue_g => UserLastValue_g,
            UserErrorMask_g => UserErrorMask_g
        )
        port map (
            Clk             => Clk,
            Rst             => Rst,
            In_Valid        => In_Valid,
            In_Ready        => In_Ready,
            In_Data         => In_Data,
            In_Keep         => In_Keep,
            In_Last         => In_Last,
            In_User         => In_User,
            Out_Valid       => SmpValid,
            Out_Ready       => SmpReady,
            Out_Data        => SmpData,
            Out_Last        => SmpLast,
            Out_Error       => SmpError,
            Ev_SduError     => EvSduError,
            Ev_SduDiscarded => EvSduDiscarded
        );

    -----------------------------------------------------------------------------------------------
    -- Compressor
    -----------------------------------------------------------------------------------------------
    i_core : entity work.ocp_core
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
            SupTableData_g         => SupTableData_g,
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
            WeightExpOffsets_g     => WeightExpOffsets_g,
            CustomWeights_g        => CustomWeights_g,
            WeightInitTable_g      => WeightInitTable_g,
            WeightInitResolution_g => WeightInitResolution_g,
            WeightInitValues_g     => WeightInitValues_g,
            Fidelity_g             => Fidelity_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsBitDepth_g          => AbsBitDepth_g,
            AbsErrorLimits_g       => AbsErrorLimits_g,
            RelBandDependent_g     => RelBandDependent_g,
            RelBitDepth_g          => RelBitDepth_g,
            RelErrorLimits_g       => RelErrorLimits_g,
            SampleRepResolution_g  => SampleRepResolution_g,
            DampingBandVarying_g   => DampingBandVarying_g,
            DampingTable_g         => DampingTable_g,
            Damping_g              => Damping_g,
            OffsetBandVarying_g    => OffsetBandVarying_g,
            OffsetTable_g          => OffsetTable_g,
            Offset_g               => Offset_g,
            UnaryLimit_g           => UnaryLimit_g,
            RescaleCounterSize_g   => RescaleCounterSize_g,
            InitialCountExp_g      => InitialCountExp_g,
            AccuInitBandVarying_g  => AccuInitBandVarying_g,
            AccuInitTable_g        => AccuInitTable_g,
            AccuInit_g             => AccuInit_g,
            HybridAccuInit_g       => HybridAccuInit_g,
            HybridAccuInitHigh_g   => HybridAccuInitHigh_g,
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g,
            UseInLast_g            => true,
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g,
            OutWidth_g             => OutWidth_g,
            Speculation_g          => Speculation_g,
            RamStyle_g             => RamStyle_g
        )
        port map (
            Clk                => Clk,
            Rst                => Rst,
            In_Valid           => SmpValid,
            In_Ready           => SmpReady,
            In_Data            => SmpData,
            In_Last            => SmpLast,
            In_Error           => SmpError,
            Lim_Valid          => Lim_Valid,
            Lim_Ready          => Lim_Ready,
            Lim_Data           => Lim_Data,
            Out_Valid          => WordValid,
            Out_Ready          => WordReady,
            Out_Data           => WordData,
            Out_Keep           => WordKeep,
            Out_Last           => WordLast,
            Out_Error          => WordError,
            Ecc_Sec            => EccSec,
            Ecc_Ded            => EccDed,
            Ev_ImageError      => Ev_ImageError,
            ErrInj_Channel     => ErrInj_Channel,
            ErrInj_Double      => ErrInj_Double,
            ErrInj_Valid       => ErrInj_Valid,
            Cfg_XSize          => CfgXSize,
            Cfg_YSize          => CfgYSize,
            Cfg_ZSize          => CfgZSize,
            Cfg_AbsLimit       => CfgAbsLimit,
            Cfg_RelLimit       => CfgRelLimit,
            Cfg_UserData       => CfgUserData,
            Cfg_M              => CfgM,
            Cfg_WeightInterval => CfgWeightInterval,
            Cfg_WeightVmin     => CfgWeightVmin,
            Cfg_WeightVmax     => CfgWeightVmax,
            Cfg_UnaryLimit     => CfgUnaryLimit,
            Cfg_InitCountExp   => CfgInitCountExp,
            Cfg_RescaleSize    => CfgRescaleSize,
            Cfg_AccuInit       => CfgAccuInit,
            Cfg_RefInterval    => CfgRefInterval,
            Cfg_Taken          => CfgTaken,
            Act_XSize          => ActXSize,
            Act_YSize          => ActYSize,
            Act_ZSize          => ActZSize,
            Act_AbsLimit       => ActAbsLimit,
            Act_RelLimit       => ActRelLimit,
            Act_UserData       => ActUserData,
            Act_M              => ActM,
            Act_WeightInterval => ActWeightInterval,
            Act_WeightVmin     => ActWeightVmin,
            Act_WeightVmax     => ActWeightVmax,
            Act_UnaryLimit     => ActUnaryLimit,
            Act_InitCountExp   => ActInitCountExp,
            Act_RescaleSize    => ActRescaleSize,
            Act_AccuInit       => ActAccuInit,
            Act_RefInterval    => ActRefInterval
        );

    Ecc_Sec <= EccSec;
    Ecc_Ded <= EccDed;

    -- Image counters at the output of the core
    EvImageDone    <= WordValid and WordReady and WordLast and not WordError;
    EvImageAborted <= WordValid and WordReady and WordLast and WordError;

    -----------------------------------------------------------------------------------------------
    -- Output adapter: words of the core to beats of the output stream
    -----------------------------------------------------------------------------------------------
    g_convert : if OutWidth_g /= OutStreamWidth_g generate

        i_conv : entity olo.olo_base_wconv_n2m
            generic map (
                InWidth_g  => OutWidth_g,
                OutWidth_g => OutStreamWidth_g,
                UseBe_g    => true
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                In_Valid  => WordValid,
                In_Ready  => WordReady,
                In_Data   => WordData,
                In_Be     => WordKeep,
                In_Last   => WordLast,
                Out_Valid => Out_Valid,
                Out_Ready => Out_Ready,
                Out_Data  => Out_Data,
                Out_Be    => Out_Keep,
                Out_Last  => ConvLast
            );

        -- The converter holds at most one image end (it takes no input after a last word until that
        -- word has left), so one register carries the error flag of that image
        p_flag : process (Clk) is
        begin
            if rising_edge(Clk) then
                if WordValid = '1' and WordReady = '1' and WordLast = '1' then
                    ErrFlag <= WordError;
                end if;
                if Rst = '1' then
                    ErrFlag <= '0';
                end if;
            end if;
        end process;

        Out_Last  <= ConvLast;
        Out_Error <= ErrFlag and ConvLast;

    end generate;

    g_direct : if OutWidth_g = OutStreamWidth_g generate
        Out_Valid <= WordValid;
        WordReady <= Out_Ready;
        Out_Data  <= WordData;
        Out_Keep  <= WordKeep;
        Out_Last  <= WordLast;
        Out_Error <= WordError;
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Status registers
    -----------------------------------------------------------------------------------------------
    i_mib : entity work.ocp_mib
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
            AccuInit_g             => AccuInit_g,
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g,
            HybridAccuInit_g       => HybridAccuInit_g,
            HybridAccuInitHigh_g   => HybridAccuInitHigh_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsBitDepth_g          => AbsBitDepth_g,
            AbsErrorLimits_g       => AbsErrorLimits_g,
            RelBandDependent_g     => RelBandDependent_g,
            RelBitDepth_g          => RelBitDepth_g,
            RelErrorLimits_g       => RelErrorLimits_g,
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g
        )
        port map (
            Clk                   => Clk,
            Rst                   => Rst,
            S_AxiLite_ArAddr      => S_AxiLite_ArAddr,
            S_AxiLite_ArValid     => S_AxiLite_ArValid,
            S_AxiLite_ArReady     => S_AxiLite_ArReady,
            S_AxiLite_AwAddr      => S_AxiLite_AwAddr,
            S_AxiLite_AwValid     => S_AxiLite_AwValid,
            S_AxiLite_AwReady     => S_AxiLite_AwReady,
            S_AxiLite_WData       => S_AxiLite_WData,
            S_AxiLite_WStrb       => S_AxiLite_WStrb,
            S_AxiLite_WValid      => S_AxiLite_WValid,
            S_AxiLite_WReady      => S_AxiLite_WReady,
            S_AxiLite_BResp       => S_AxiLite_BResp,
            S_AxiLite_BValid      => S_AxiLite_BValid,
            S_AxiLite_BReady      => S_AxiLite_BReady,
            S_AxiLite_RData       => S_AxiLite_RData,
            S_AxiLite_RResp       => S_AxiLite_RResp,
            S_AxiLite_RValid      => S_AxiLite_RValid,
            S_AxiLite_RReady      => S_AxiLite_RReady,
            Ev_ImageDone          => EvImageDone,
            Ev_ImageAborted       => EvImageAborted,
            Ev_SduError           => EvSduError,
            Ev_SduDiscarded       => EvSduDiscarded,
            Ecc_Sec               => EccSec,
            Ecc_Ded               => EccDed,
            Cfg_XSize             => CfgXSize,
            Cfg_YSize             => CfgYSize,
            Cfg_ZSize             => CfgZSize,
            Cfg_AbsLimit          => CfgAbsLimit,
            Cfg_RelLimit          => CfgRelLimit,
            Cfg_UserData          => CfgUserData,
            Cfg_M                 => CfgM,
            Cfg_WeightInterval    => CfgWeightInterval,
            Cfg_WeightVmin        => CfgWeightVmin,
            Cfg_WeightVmax        => CfgWeightVmax,
            Cfg_UnaryLimit        => CfgUnaryLimit,
            Cfg_InitCountExp      => CfgInitCountExp,
            Cfg_RescaleSize       => CfgRescaleSize,
            Cfg_AccuInit          => CfgAccuInit,
            Cfg_RefInterval       => CfgRefInterval,
            Cfg_Taken             => CfgTaken,
            Act_XSize             => ActXSize,
            Act_YSize             => ActYSize,
            Act_ZSize             => ActZSize,
            Act_AbsLimit          => ActAbsLimit,
            Act_RelLimit          => ActRelLimit,
            Act_UserData          => ActUserData,
            Act_M                 => ActM,
            Act_WeightInterval    => ActWeightInterval,
            Act_WeightVmin        => ActWeightVmin,
            Act_WeightVmax        => ActWeightVmax,
            Act_UnaryLimit        => ActUnaryLimit,
            Act_InitCountExp      => ActInitCountExp,
            Act_RescaleSize       => ActRescaleSize,
            Act_AccuInit          => ActAccuInit,
            Act_RefInterval       => ActRefInterval
        );

end architecture;
