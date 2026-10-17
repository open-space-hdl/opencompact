---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- OpenCompact core: CCSDS 123.0-B-2 compressor for multispectral and hyperspectral images. The
-- image samples enter in the input order of the compressed image (BI or BSQ), the compressed image
-- (header and body) leaves as a byte stream. All image and compression parameters are generics.
--
-- Documentation: hdl/ocp_core/docs/specification.md, docs/user_guide.md

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
entity ocp_core is
    generic (
        -- Image (CCSDS 3, 5.3.2)
        XSize_g                : positive range 1 to 65536 := 8;
        YSize_g                : positive range 1 to 65536 := 8;
        ZSize_g                : positive range 1 to 65536 := 4;
        DynamicRange_g         : positive range 2 to 32    := 16;
        SignedSamples_g        : boolean                   := false;
        UserData_g             : natural range 0 to 255    := 0;
        EncodingOrder_g        : string                    := "BI";
        SubFrameDepth_g        : positive range 1 to 65536 := 4;
        OutputWordSize_g       : positive range 1 to 8     := 1;
        EntropyCoder_g         : string                    := "SAMPLE_ADAPTIVE";
        SupTableCount_g        : natural range 0 to 15     := 0;
        SupTableData_g         : std_logic_vector          := x"00";
        -- Predictor (CCSDS 4)
        PredictionBands_g      : natural range 0 to 15     := 3;
        PredictionMode_g       : string                    := "FULL";
        LocalSum_g             : string                    := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive range 32 to 64   := 64;
        WeightResolution_g     : positive range 4 to 19    := 13;
        WeightUpdateInterval_g : positive range 4 to 11    := 6;
        WeightUpdateVmin_g     : integer range -6 to 9     := -1;
        WeightUpdateVmax_g     : integer range -6 to 9     := 3;
        WeightExpOffsetsUsed_g : boolean                   := false;
        WeightExpOffsetTable_g : boolean                   := false;
        WeightExpOffsets_g     : integer_vector            := (0 => 0);
        CustomWeights_g        : boolean                   := false;
        WeightInitTable_g      : boolean                   := false;
        WeightInitResolution_g : natural range 0 to 22     := 0;
        WeightInitValues_g     : integer_vector            := (0 => 0);
        -- Quantizer (CCSDS 4.8)
        Fidelity_g             : string                    := "LOSSLESS";
        PeriodicUpdate_g       : boolean                   := false;
        UpdatePeriodExp_g      : natural range 0 to 9      := 0;
        AbsBandDependent_g     : boolean                   := false;
        AbsBitDepth_g          : positive range 1 to 16    := 1;
        AbsErrorLimits_g       : integer_vector            := (0 => 0);
        RelBandDependent_g     : boolean                   := false;
        RelBitDepth_g          : positive range 1 to 16    := 1;
        RelErrorLimits_g       : integer_vector            := (0 => 0);
        -- Sample representatives (CCSDS 4.9)
        SampleRepResolution_g  : natural range 0 to 4      := 0;
        DampingBandVarying_g   : boolean                   := false;
        DampingTable_g         : boolean                   := false;
        Damping_g              : integer_vector            := (0 => 0);
        OffsetBandVarying_g    : boolean                   := false;
        OffsetTable_g          : boolean                   := false;
        Offset_g               : integer_vector            := (0 => 0);
        -- Sample-adaptive and hybrid entropy coder (CCSDS 5.4.3.2, 5.4.3.3)
        UnaryLimit_g           : positive range 8 to 32    := 16;
        RescaleCounterSize_g   : positive range 4 to 11    := 6;
        InitialCountExp_g      : positive range 1 to 8     := 1;
        AccuInitBandVarying_g  : boolean                   := false;
        AccuInitTable_g        : boolean                   := false;
        AccuInit_g             : integer_vector            := (0 => 3);
        HybridAccuInit_g       : integer_vector            := (0 => 0);
        HybridAccuInitHigh_g   : integer_vector            := (0 => 0);
        -- Block-adaptive entropy coder (CCSDS 5.4.3.4)
        BlockSize_g            : positive                  := 16;
        RestrictedCodes_g      : boolean                   := false;
        RefInterval_g          : positive range 1 to 4096  := 4096;
        -- Image framing: In_Last marks the last sample of every image (In_Error with it: the image ends
        -- with an error), errors are flagged on Out_Error
        UseInLast_g            : boolean                   := false;
        -- Implementation: width of the compressed image interface in bits (8, 16, 32 or 64), speculative
        -- weight loop of the predictor, memory style
        OutWidth_g             : positive                  := 8;
        Speculation_g          : boolean                   := true;
        RamStyle_g             : string                    := "auto"
    );
    port (
        Clk            : in    std_logic;
        Rst            : in    std_logic;
        -- Image samples in the input order (unsigned or two's complement); In_Last on the last sample
        -- of every image, In_Error with In_Last: the image ends with an error (UseInLast_g, both ignored
        -- otherwise)
        In_Valid       : in    std_logic;
        In_Ready       : out   std_logic;
        In_Data        : in    std_logic_vector(DynamicRange_g - 1 downto 0);
        In_Last        : in    std_logic                     := '0';
        In_Error       : in    std_logic                     := '0';
        -- Error limit values for periodic error limit updating
        Lim_Valid      : in    std_logic                     := '0';
        Lim_Ready      : out   std_logic;
        Lim_Data       : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Compressed image: byte n of a word in Out_Data(8n + 7 downto 8n), the first byte in bits 7:0;
        -- the last word of an image marks its valid bytes, contiguous from byte 0; Out_Error on the
        -- last word of an image with a framing error ('0' on every other word)
        Out_Valid      : out   std_logic;
        Out_Ready      : in    std_logic;
        Out_Data       : out   std_logic_vector(OutWidth_g - 1 downto 0);
        Out_Keep       : out   std_logic_vector(OutWidth_g / 8 - 1 downto 0);
        Out_Last       : out   std_logic;
        Out_Error      : out   std_logic;
        -- Memory errors (pulses): corrected single error, detected double error
        Ecc_Sec        : out   std_logic;
        Ecc_Ded        : out   std_logic;
        -- Framing error of an image (pulse): In_Last before or missing on the last sample, or In_Error
        Ev_ImageError  : out   std_logic;
        -- Error injection into the next write of memory ErrInj_Channel (user guide, memories): a single
        -- (corrected) or a double (detected) bit error
        ErrInj_Channel : in    std_logic_vector(3 downto 0)  := (others => '0');
        ErrInj_Double  : in    std_logic                     := '0';
        ErrInj_Valid   : in    std_logic                     := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_core is

    constant Coder_c     : natural := entropyCoderCode(EntropyCoder_g);
    -- Accumulator initialisation values in use: k''_z of every band or the constant K (CCSDS 5.4.3.2.3.3)
    constant AccuCount_c : positive := choose(AccuInitBandVarying_g, ZSize_g, 1);
    constant ItemW_c     : positive := maximum(DynamicRange_g, 16);
    constant ZW_c        : positive := log2ceil(ZSize_g + 1);

    -- Entropy coder input sequence
    signal Item_Valid : std_logic;
    signal Item_Ready : std_logic;
    signal Item_Data  : std_logic_vector(ItemW_c - 1 downto 0);
    signal Item_Kind  : std_logic_vector(1 downto 0);
    signal Item_Band  : std_logic_vector(ZW_c - 1 downto 0);
    signal Item_First : std_logic;
    signal Item_Init  : std_logic;
    signal Item_Last  : std_logic;

    -- Codewords of the entropy coder
    signal Cw_Valid  : std_logic;
    signal Cw_Ready  : std_logic;
    signal Cw_Data   : std_logic_vector(CwWidth_c - 1 downto 0);
    signal Cw_Length : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal Cw_Last   : std_logic;

    -- Header bytes
    signal Hdr_Start  : std_logic;
    signal Hdr_Valid  : std_logic;
    signal Hdr_Ready  : std_logic;
    signal Hdr_Data   : std_logic_vector(63 downto 0);
    signal Hdr_Length : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal Hdr_Last   : std_logic;

    -- Bit packer input
    signal Pk_Valid  : std_logic;
    signal Pk_Ready  : std_logic;
    signal Pk_Data   : std_logic_vector(CwWidth_c - 1 downto 0);
    signal Pk_Length : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal Pk_Last   : std_logic;

    -- Output stream of the bit packer; the ports are assigned together below, so that they change in the
    -- same delta cycle (the Open Logic width converters check the byte enables of every valid word)
    signal OutValid : std_logic;
    signal OutLast  : std_logic;
    signal OutData  : std_logic_vector(OutWidth_g - 1 downto 0);
    signal OutKeep  : std_logic_vector(OutWidth_g / 8 - 1 downto 0);

    -- Image framing: samples and error limit values to the predictor, image end at the bit packer
    -- input, abort of an image (clears the predictor and the entropy coder, then ends the image)
    signal SmpValid : std_logic;
    signal SmpReady : std_logic;
    signal ValValid : std_logic;
    signal ValReady : std_logic;
    signal PkEnd    : std_logic;
    signal Flush    : std_logic;
    signal PipeRst  : std_logic;
    signal EndValid : std_logic;
    signal EndReady : std_logic;

    -- Image sequencing: header first, then the body
    signal InBody    : std_logic;
    signal StartPend : std_logic;
    signal ImgStart  : std_logic;
    signal Waiting   : natural range 0 to 15;
    signal PredSec   : std_logic;
    signal PredDed   : std_logic;
    signal CoderSec  : std_logic;
    signal CoderDed  : std_logic;
    signal InjStats  : std_logic;
    signal InjBuffer : std_logic;

begin

    assert OutWidth_g = 8 or OutWidth_g = 16 or OutWidth_g = 32 or OutWidth_g = 64
        report "ocp_core: OutWidth_g must be 8, 16, 32 or 64"
        severity failure;

    -- Parameter ranges of the standard that depend on other parameters (CO-CF-01 to CO-CF-03): the elaboration stops
    -- instead of producing compressed images that contradict their header
    assert encodingOrderCode(EncodingOrder_g) = OrderBsq_c or SubFrameDepth_g <= ZSize_g
        report "ocp_core: SubFrameDepth_g must be 1 to ZSize_g (CCSDS 5.4.2.2.1)"
        severity failure;

    assert Coder_c /= CoderBlock_c or BlockSize_g = 8 or BlockSize_g = 16 or BlockSize_g = 32 or BlockSize_g = 64
        report "ocp_core: BlockSize_g must be 8, 16, 32 or 64 (CCSDS 5.4.3.4.2.4)"
        severity failure;

    assert Coder_c /= CoderBlock_c or not RestrictedCodes_g or DynamicRange_g <= 4
        report "ocp_core: RestrictedCodes_g requires DynamicRange_g <= 4 (CCSDS 5.3.4.4, 5.4.3.4.2.6)"
        severity failure;

    assert Coder_c = CoderBlock_c or RescaleCounterSize_g >= maximum(4, InitialCountExp_g + 1)
        report "ocp_core: RescaleCounterSize_g must be max(4, InitialCountExp_g + 1) to 11 (CCSDS 5.4.3.2.3.4, " &
               "5.4.3.3.4.5)"
        severity failure;

    g_accu_init : for i in 0 to AccuCount_c - 1 generate
        assert Coder_c /= CoderSample_c or (vecElem(AccuInit_g, i) >= 0 and
                                            vecElem(AccuInit_g, i) <= minimum(DynamicRange_g - 2, 14))
            report "ocp_core: AccuInit_g values must be 0 to min(DynamicRange_g - 2, 14) (CCSDS 5.4.3.2.3.3)"
            severity failure;
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Image sequencing
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            -- Header of an image once its first sample or error limit value has been accepted (the
            -- images accepted at the input and still without a header are counted)
            if ImgStart = '1' and Hdr_Start = '0' then
                Waiting <= Waiting + 1;
            elsif ImgStart = '0' and Hdr_Start = '1' then
                Waiting <= Waiting - 1;
            end if;
            if Hdr_Start = '1' then
                StartPend <= '0';
            end if;
            if Hdr_Valid = '1' and Hdr_Ready = '1' and Hdr_Last = '1' then
                InBody <= '1';
            end if;
            -- The image ends with the last codeword (or the end of an aborted image); the bit packer
            -- appends the fill bits before it takes the header of the next image
            if PkEnd = '1' then
                InBody    <= '0';
                StartPend <= '1';
            end if;
            if Rst = '1' then
                InBody    <= '0';
                StartPend <= '1';
                Waiting   <= 0;
            end if;
        end if;
    end process;

    Hdr_Start <= StartPend and toSl(Waiting > 0);

    -- Bit packer input: header bytes, then the codewords of the entropy coder; an aborted image ends
    -- with a last codeword of one zero bit from the image framer (a last codeword is never empty)
    Pk_Valid  <= (Cw_Valid or EndValid) when InBody = '1' else Hdr_Valid;
    Pk_Data   <= (others => '0') when EndValid = '1' else
                 Cw_Data when InBody = '1' else
                 std_logic_vector(resize(unsigned(Hdr_Data), CwWidth_c));
    Pk_Length <= std_logic_vector(to_unsigned(1, CwLenWidth_c)) when EndValid = '1' else
                 Cw_Length when InBody = '1' else
                 Hdr_Length;
    Pk_Last   <= (Cw_Last or EndValid) when InBody = '1' else '0';
    Cw_Ready  <= Pk_Ready when InBody = '1' and EndValid = '0' else '0';
    Hdr_Ready <= Pk_Ready when InBody = '0' else '0';
    EndReady  <= Pk_Ready;
    PkEnd     <= Pk_Valid and Pk_Ready and Pk_Last;

    -----------------------------------------------------------------------------------------------
    -- Image framing
    -----------------------------------------------------------------------------------------------
    g_framer : if UseInLast_g generate

        i_framer : entity work.ocp_image_framer
            generic map (
                XSize_g => XSize_g,
                YSize_g => YSize_g,
                ZSize_g => ZSize_g
            )
            port map (
                Clk           => Clk,
                Rst           => Rst,
                In_Valid      => In_Valid,
                In_Ready      => In_Ready,
                In_Last       => In_Last,
                In_Error      => In_Error,
                Lim_Valid     => Lim_Valid,
                Lim_Ready     => Lim_Ready,
                Smp_Valid     => SmpValid,
                Smp_Ready     => SmpReady,
                Val_Valid     => ValValid,
                Val_Ready     => ValReady,
                Img_Start     => ImgStart,
                Img_End       => PkEnd,
                Img_Body      => InBody,
                Flush         => Flush,
                End_Valid     => EndValid,
                End_Ready     => EndReady,
                Out_Valid     => OutValid,
                Out_Ready     => Out_Ready,
                Out_Last      => OutLast,
                Out_Error     => Out_Error,
                Ev_ImageError => Ev_ImageError
            );

    end generate;

    g_direct : if not UseInLast_g generate
        SmpValid      <= In_Valid;
        In_Ready      <= SmpReady;
        ValValid      <= Lim_Valid;
        Lim_Ready     <= ValReady;
        Flush         <= '0';
        EndValid      <= '0';
        Out_Error     <= '0';
        Ev_ImageError <= '0';
    end generate;

    -- An aborted image clears the predictor and the entropy coder
    PipeRst <= Rst or Flush;

    -----------------------------------------------------------------------------------------------
    -- Header
    -----------------------------------------------------------------------------------------------
    i_header : entity work.ocp_header
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
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            Start      => Hdr_Start,
            Out_Valid  => Hdr_Valid,
            Out_Ready  => Hdr_Ready,
            Out_Data   => Hdr_Data,
            Out_Length => Hdr_Length,
            Out_Last   => Hdr_Last
        );

    -----------------------------------------------------------------------------------------------
    -- Predictor
    -----------------------------------------------------------------------------------------------
    i_predictor : entity work.ocp_predictor
        generic map (
            XSize_g                => XSize_g,
            YSize_g                => YSize_g,
            ZSize_g                => ZSize_g,
            DynamicRange_g         => DynamicRange_g,
            SignedSamples_g        => SignedSamples_g,
            EncodingOrder_g        => EncodingOrder_g,
            SubFrameDepth_g        => SubFrameDepth_g,
            PredictionBands_g      => PredictionBands_g,
            PredictionMode_g       => PredictionMode_g,
            LocalSum_g             => LocalSum_g,
            RegisterSize_g         => RegisterSize_g,
            WeightResolution_g     => WeightResolution_g,
            WeightUpdateInterval_g => WeightUpdateInterval_g,
            WeightUpdateVmin_g     => WeightUpdateVmin_g,
            WeightUpdateVmax_g     => WeightUpdateVmax_g,
            WeightExpOffsetsUsed_g => WeightExpOffsetsUsed_g,
            WeightExpOffsets_g     => WeightExpOffsets_g,
            CustomWeights_g        => CustomWeights_g,
            WeightInitResolution_g => WeightInitResolution_g,
            WeightInitValues_g     => WeightInitValues_g,
            Fidelity_g             => Fidelity_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsErrorLimits_g       => AbsErrorLimits_g,
            RelBandDependent_g     => RelBandDependent_g,
            RelErrorLimits_g       => RelErrorLimits_g,
            SampleRepResolution_g  => SampleRepResolution_g,
            Damping_g              => Damping_g,
            Offset_g               => Offset_g,
            Speculation_g          => Speculation_g,
            RamStyle_g             => RamStyle_g
        )
        port map (
            Clk            => Clk,
            Rst            => PipeRst,
            In_Valid       => SmpValid,
            In_Ready       => SmpReady,
            In_Data        => In_Data,
            Lim_Valid      => ValValid,
            Lim_Ready      => ValReady,
            Lim_Data       => Lim_Data,
            Img_Start      => ImgStart,
            Out_Valid      => Item_Valid,
            Out_Ready      => Item_Ready,
            Out_Data       => Item_Data,
            Out_Kind       => Item_Kind,
            Out_Band       => Item_Band,
            Out_First      => Item_First,
            Out_Init       => Item_Init,
            Out_Last       => Item_Last,
            Ecc_Sec        => PredSec,
            Ecc_Ded        => PredDed,
            ErrInj_Channel => ErrInj_Channel,
            ErrInj_Double  => ErrInj_Double,
            ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Entropy coder
    -----------------------------------------------------------------------------------------------
    g_sample : if Coder_c = CoderSample_c generate

        i_coder : entity work.ocp_sample_adaptive_coder
            generic map (
                ZSize_g               => ZSize_g,
                DynamicRange_g        => DynamicRange_g,
                UnaryLimit_g          => UnaryLimit_g,
                RescaleCounterSize_g  => RescaleCounterSize_g,
                InitialCountExp_g     => InitialCountExp_g,
                AccuInitBandVarying_g => AccuInitBandVarying_g,
                AccuInit_g            => AccuInit_g,
                AbsBitDepth_g         => AbsBitDepth_g,
                RelBitDepth_g         => RelBitDepth_g,
                RamStyle_g            => RamStyle_g
            )
            port map (
                Clk           => Clk,
                Rst           => PipeRst,
                In_Valid      => Item_Valid,
                In_Ready      => Item_Ready,
                In_Data       => Item_Data,
                In_Kind       => Item_Kind,
                In_Band       => Item_Band,
                In_First      => Item_First,
                In_Init       => Item_Init,
                In_Last       => Item_Last,
                Cw_Valid      => Cw_Valid,
                Cw_Ready      => Cw_Ready,
                Cw_Data       => Cw_Data,
                Cw_Length     => Cw_Length,
                Cw_Last       => Cw_Last,
                Ecc_Sec       => CoderSec,
                Ecc_Ded       => CoderDed,
                ErrInj_Stats  => InjStats,
                ErrInj_Buffer => InjBuffer,
                ErrInj_Double => ErrInj_Double
            );

    end generate;

    g_hybrid : if Coder_c = CoderHybrid_c generate

        i_coder : entity work.ocp_hybrid_coder
            generic map (
                XSize_g              => XSize_g,
                YSize_g              => YSize_g,
                ZSize_g              => ZSize_g,
                DynamicRange_g       => DynamicRange_g,
                UnaryLimit_g         => UnaryLimit_g,
                RescaleCounterSize_g => RescaleCounterSize_g,
                InitialCountExp_g    => InitialCountExp_g,
                HybridAccuInit_g     => HybridAccuInit_g,
                HybridAccuInitHigh_g => HybridAccuInitHigh_g,
                AbsBitDepth_g        => AbsBitDepth_g,
                RelBitDepth_g        => RelBitDepth_g,
                RamStyle_g           => RamStyle_g
            )
            port map (
                Clk           => Clk,
                Rst           => PipeRst,
                In_Valid      => Item_Valid,
                In_Ready      => Item_Ready,
                In_Data       => Item_Data,
                In_Kind       => Item_Kind,
                In_Band       => Item_Band,
                In_First      => Item_First,
                In_Init       => Item_Init,
                In_Last       => Item_Last,
                Cw_Valid      => Cw_Valid,
                Cw_Ready      => Cw_Ready,
                Cw_Data       => Cw_Data,
                Cw_Length     => Cw_Length,
                Cw_Last       => Cw_Last,
                Ecc_Sec       => CoderSec,
                Ecc_Ded       => CoderDed,
                ErrInj_Stats  => InjStats,
                ErrInj_Buffer => InjBuffer,
                ErrInj_Double => ErrInj_Double
            );

    end generate;

    g_block : if Coder_c = CoderBlock_c generate

        i_coder : entity work.ocp_block_adaptive_coder
            generic map (
                DynamicRange_g    => DynamicRange_g,
                BlockSize_g       => BlockSize_g,
                RestrictedCodes_g => RestrictedCodes_g,
                RefInterval_g     => RefInterval_g,
                RamStyle_g        => RamStyle_g
            )
            port map (
                Clk           => Clk,
                Rst           => PipeRst,
                In_Valid      => Item_Valid,
                In_Ready      => Item_Ready,
                In_Data       => Item_Data,
                In_Last       => Item_Last,
                Cw_Valid      => Cw_Valid,
                Cw_Ready      => Cw_Ready,
                Cw_Data       => Cw_Data,
                Cw_Length     => Cw_Length,
                Cw_Last       => Cw_Last,
                Ecc_Sec       => CoderSec,
                Ecc_Ded       => CoderDed,
                ErrInj_Buffer => InjBuffer,
                ErrInj_Double => ErrInj_Double
            );

    end generate;

    -----------------------------------------------------------------------------------------------
    -- Bit packer
    -----------------------------------------------------------------------------------------------
    i_packer : entity work.ocp_bit_packer
        generic map (
            OutputWordSize_g => OutputWordSize_g,
            OutWidth_g       => OutWidth_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => Pk_Valid,
            In_Ready  => Pk_Ready,
            In_Data   => Pk_Data,
            In_Length => Pk_Length,
            In_Last   => Pk_Last,
            Out_Valid => OutValid,
            Out_Ready => Out_Ready,
            Out_Data  => OutData,
            Out_Keep  => OutKeep,
            Out_Last  => OutLast
        );

    -- Error injection: channel 12 statistics memory, channel 13 codeword buffer of the entropy coder
    InjStats  <= ErrInj_Valid when to_integer(unsigned(ErrInj_Channel)) = 12 else '0';
    InjBuffer <= ErrInj_Valid when to_integer(unsigned(ErrInj_Channel)) = 13 else '0';

    Out_Valid <= OutValid;
    Out_Data  <= OutData;
    Out_Keep  <= OutKeep;
    Out_Last  <= OutLast;
    Ecc_Sec   <= PredSec or CoderSec;
    Ecc_Ded   <= PredDed or CoderDed;

end architecture;
