---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Status interface of an OpenCompact channel: AXI4-Lite slave with the identification, the
-- generics that define the compressed images and 32-bit saturating counters of the images, the
-- faulty and discarded SDUs and the memory errors; a write to a counter clears it.
--
-- Documentation: hdl/ocp_mib/docs/specification.md, register map hdl/ocp_mib/docs/register_map.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;

library work;
    use work.ocp_pkg.all;
    use work.ocp_regs_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_mib is
    generic (
        -- Channel
        InStreamWidth_g        : positive                  := 128;
        OutStreamWidth_g       : positive                  := 128;
        OutWidth_g             : positive                  := 8;
        Speculation_g          : boolean                   := true;
        -- Image and compressed image
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
        Fidelity_g             : string                    := "LOSSLESS";
        SupTableCount_g        : natural range 0 to 15     := 0;
        -- Predictor
        PredictionBands_g      : natural range 0 to 15     := 3;
        PredictionMode_g       : string                    := "FULL";
        LocalSum_g             : string                    := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive range 32 to 64   := 64;
        SampleRepResolution_g  : natural range 0 to 4      := 0;
        PeriodicUpdate_g       : boolean                   := false;
        UpdatePeriodExp_g      : natural range 0 to 9      := 0;
        WeightResolution_g     : positive range 4 to 19    := 13;
        WeightUpdateInterval_g : positive range 4 to 11    := 6;
        WeightUpdateVmin_g     : integer range -6 to 9     := -1;
        WeightUpdateVmax_g     : integer range -6 to 9     := 3;
        WeightExpOffsetsUsed_g : boolean                   := false;
        CustomWeights_g        : boolean                   := false;
        WeightInitResolution_g : natural range 0 to 22     := 0;
        -- Entropy coders
        UnaryLimit_g           : positive range 8 to 32    := 16;
        RescaleCounterSize_g   : positive range 4 to 11    := 6;
        InitialCountExp_g      : positive range 1 to 8     := 1;
        AccuInitBandVarying_g  : boolean                   := false;
        AccuInit_g             : integer_vector            := (0 => 3);
        BlockSize_g            : positive                  := 16;
        RestrictedCodes_g      : boolean                   := false;
        RefInterval_g          : positive range 1 to 4096  := 4096;
        -- Error limits
        AbsBandDependent_g     : boolean                   := false;
        AbsBitDepth_g          : positive range 1 to 16    := 1;
        AbsErrorLimits_g       : integer_vector            := (0 => 0);
        RelBandDependent_g     : boolean                   := false;
        RelBitDepth_g          : positive range 1 to 16    := 1;
        RelErrorLimits_g       : integer_vector            := (0 => 0);
        -- Runtime configuration of the image dimensions and error limit values (NEXT_X to NEXT_LIMITS,
        -- CONTROL, STATUS)
        RuntimeConfig_g        : boolean                   := false
    );
    port (
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- AXI4-Lite slave
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
        -- Events (pulses)
        Ev_ImageDone      : in    std_logic;
        Ev_ImageAborted   : in    std_logic;
        Ev_SduError       : in    std_logic;
        Ev_SduDiscarded   : in    std_logic;
        Ecc_Sec           : in    std_logic;
        Ecc_Ded           : in    std_logic;
        -- Runtime configuration: committed configuration for the core (all five outputs change in the same
        -- clock cycle), the pulse of the core when it takes them, the values the core took for the last
        -- image
        Cfg_XSize         : out   std_logic_vector(16 downto 0);
        Cfg_YSize         : out   std_logic_vector(16 downto 0);
        Cfg_ZSize         : out   std_logic_vector(16 downto 0);
        Cfg_AbsLimit      : out   std_logic_vector(15 downto 0);
        Cfg_RelLimit      : out   std_logic_vector(15 downto 0);
        Cfg_Taken         : in    std_logic                     := '0';
        Act_XSize         : in    std_logic_vector(16 downto 0) := (others => '0');
        Act_YSize         : in    std_logic_vector(16 downto 0) := (others => '0');
        Act_ZSize         : in    std_logic_vector(16 downto 0) := (others => '0');
        Act_AbsLimit      : in    std_logic_vector(15 downto 0) := (others => '0');
        Act_RelLimit      : in    std_logic_vector(15 downto 0) := (others => '0')
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_mib is

    subtype Word_t is std_logic_vector(31 downto 0);

    type WordArr_t is array (natural range <>) of Word_t;

    -- Registers ID to BLOCK (index = address / 4) and the counters (from IMAGES_DONE)
    constant NumConfig_c   : positive := RegBlock_c / 4 + 1;
    constant NumCounters_c : positive := 6;
    constant FirstCnt_c    : natural  := RegImagesDone_c / 4;

    constant Order_c    : natural := encodingOrderCode(EncodingOrder_g);
    constant Coder_c    : natural := entropyCoderCode(EntropyCoder_g);
    constant Fid_c      : natural := fidelityCode(Fidelity_g);
    constant Periodic_c : boolean := PeriodicUpdate_g and Fid_c /= FidLossless_c;
    constant UseAbs_c   : boolean := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
    constant UseRel_c   : boolean := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
    -- Images of width 1 need reduced prediction and column-oriented local sums (CCSDS 4.3.1, 4.4.1)
    constant Wide_c     : boolean := fullPrediction(PredictionMode_g) or localSumCode(LocalSum_g) = SumWideNeighbor_c or
                                     localSumCode(LocalSum_g) = SumNarrowNeighbor_c;

    -- Band-independent error limit values of the generics (zero for a method not in use or with band-dependent
    -- limits): LIMITS without the runtime configuration, reset values of NEXT_LIMITS and of the configuration
    function absConst return natural is
    begin
        if UseAbs_c and not AbsBandDependent_g then
            return vecElem(AbsErrorLimits_g, 0);
        end if;
        return 0;
    end function;

    function relConst return natural is
    begin
        if UseRel_c and not RelBandDependent_g then
            return vecElem(RelErrorLimits_g, 0);
        end if;
        return 0;
    end function;

    constant AbsConst_c : natural := absConst;
    constant RelConst_c : natural := relConst;

    -- Value into the bits hi downto lo (two's complement for negative values)
    function put (w : Word_t; value : integer; lo : natural; hi : natural) return Word_t is
        variable W_v : Word_t := w;
    begin
        if value < 0 then
            W_v(hi downto lo) := std_logic_vector(to_signed(value, hi - lo + 1));
        else
            W_v(hi downto lo) := std_logic_vector(to_unsigned(value, hi - lo + 1));
        end if;
        return W_v;
    end function;

    function configWords return WordArr_t is
        variable W_v : WordArr_t(0 to NumConfig_c - 1) := (others => (others => '0'));
        variable A_v : natural;
    begin
        W_v(RegId_c / 4) := RegMapId_c;
        -- GENERICS
        A_v      := RegGenerics_c / 4;
        W_v(A_v) := put(W_v(A_v), InStreamWidth_g / 8, GenericsInStreamBytesLo_c, GenericsInStreamBytesHi_c);
        W_v(A_v) := put(W_v(A_v), OutStreamWidth_g / 8, GenericsOutStreamBytesLo_c, GenericsOutStreamBytesHi_c);
        W_v(A_v) := put(W_v(A_v), OutWidth_g / 8, GenericsOutBytesLo_c, GenericsOutBytesHi_c);
        W_v(A_v) := put(W_v(A_v), (DynamicRange_g + 7) / 8, GenericsSampleBytesLo_c, GenericsSampleBytesHi_c);
        W_v(A_v) := put(W_v(A_v), toInt(Speculation_g), GenericsSpeculation_c, GenericsSpeculation_c);
        W_v(A_v) := put(W_v(A_v), toInt(RuntimeConfig_g), GenericsRuntimeConfig_c, GenericsRuntimeConfig_c);
        -- IMAGE_X, IMAGE_Y, IMAGE_Z
        W_v(RegImageX_c / 4) := put(W_v(RegImageX_c / 4), XSize_g, ImageXSizeLo_c, ImageXSizeHi_c);
        W_v(RegImageY_c / 4) := put(W_v(RegImageY_c / 4), YSize_g, ImageYSizeLo_c, ImageYSizeHi_c);
        W_v(RegImageZ_c / 4) := put(W_v(RegImageZ_c / 4), ZSize_g, ImageZSizeLo_c, ImageZSizeHi_c);
        -- SAMPLES
        A_v      := RegSamples_c / 4;
        W_v(A_v) := put(W_v(A_v), UserData_g, SamplesUserDataLo_c, SamplesUserDataHi_c);
        W_v(A_v) := put(W_v(A_v), toInt(SignedSamples_g), SamplesSigned_c, SamplesSigned_c);
        W_v(A_v) := put(W_v(A_v), DynamicRange_g, SamplesDynamicRangeLo_c, SamplesDynamicRangeHi_c);
        -- ORDER
        A_v := RegOrder_c / 4;
        if Order_c = OrderBi_c then
            W_v(A_v) := put(W_v(A_v), SubFrameDepth_g, OrderSubFrameDepthLo_c, OrderSubFrameDepthHi_c);
        end if;
        W_v(A_v) := put(W_v(A_v), Order_c, OrderEncoding_c, OrderEncoding_c);
        -- CODER
        A_v      := RegCoder_c / 4;
        W_v(A_v) := put(W_v(A_v), SupTableCount_g, CoderSupTablesLo_c, CoderSupTablesHi_c);
        W_v(A_v) := put(W_v(A_v), Fid_c, CoderFidelityLo_c, CoderFidelityHi_c);
        W_v(A_v) := put(W_v(A_v), Coder_c, CoderEntropyCoderLo_c, CoderEntropyCoderHi_c);
        W_v(A_v) := put(W_v(A_v), OutputWordSize_g, CoderOutputWordSizeLo_c, CoderOutputWordSizeHi_c);
        -- PREDICTOR
        A_v := RegPredictor_c / 4;
        if Periodic_c then
            W_v(A_v) := put(W_v(A_v), UpdatePeriodExp_g, PredictorUpdatePeriodExpLo_c, PredictorUpdatePeriodExpHi_c);
        end if;
        W_v(A_v) := put(W_v(A_v), toInt(Periodic_c), PredictorPeriodicUpdate_c, PredictorPeriodicUpdate_c);
        W_v(A_v) := put(W_v(A_v), SampleRepResolution_g, PredictorSampleRepResolutionLo_c,
                        PredictorSampleRepResolutionHi_c);
        W_v(A_v) := put(W_v(A_v), RegisterSize_g, PredictorRegisterSizeLo_c, PredictorRegisterSizeHi_c);
        W_v(A_v) := put(W_v(A_v), localSumCode(LocalSum_g), PredictorLocalSumLo_c, PredictorLocalSumHi_c);
        W_v(A_v) := put(W_v(A_v), toInt(not fullPrediction(PredictionMode_g)), PredictorReduced_c, PredictorReduced_c);
        W_v(A_v) := put(W_v(A_v), PredictionBands_g, PredictorBandsLo_c, PredictorBandsHi_c);
        -- WEIGHTS
        A_v := RegWeights_c / 4;
        if CustomWeights_g then
            W_v(A_v) := put(W_v(A_v), WeightInitResolution_g, WeightsInitResolutionLo_c, WeightsInitResolutionHi_c);
        end if;
        W_v(A_v) := put(W_v(A_v), toInt(CustomWeights_g), WeightsCustomInit_c, WeightsCustomInit_c);
        W_v(A_v) := put(W_v(A_v), toInt(WeightExpOffsetsUsed_g), WeightsExpOffsets_c, WeightsExpOffsets_c);
        W_v(A_v) := put(W_v(A_v), WeightUpdateVmax_g, WeightsVmaxLo_c, WeightsVmaxHi_c);
        W_v(A_v) := put(W_v(A_v), WeightUpdateVmin_g, WeightsVminLo_c, WeightsVminHi_c);
        W_v(A_v) := put(W_v(A_v), WeightUpdateInterval_g, WeightsUpdateIntervalLo_c, WeightsUpdateIntervalHi_c);
        W_v(A_v) := put(W_v(A_v), WeightResolution_g, WeightsResolutionLo_c, WeightsResolutionHi_c);
        -- ADAPTIVE: sample-adaptive and hybrid coder; the accumulator initialisation constant of the
        -- sample-adaptive coder is 15 when it is band-dependent (as in the header)
        A_v := RegAdaptive_c / 4;
        if Coder_c = CoderSample_c then
            if AccuInitBandVarying_g then
                W_v(A_v) := put(W_v(A_v), 15, AdaptiveAccuInitLo_c, AdaptiveAccuInitHi_c);
            else
                W_v(A_v) := put(W_v(A_v), vecElem(AccuInit_g, 0), AdaptiveAccuInitLo_c, AdaptiveAccuInitHi_c);
            end if;
        end if;
        if Coder_c /= CoderBlock_c then
            W_v(A_v) := put(W_v(A_v), InitialCountExp_g, AdaptiveInitialCountLo_c, AdaptiveInitialCountHi_c);
            W_v(A_v) := put(W_v(A_v), RescaleCounterSize_g, AdaptiveRescaleSizeLo_c, AdaptiveRescaleSizeHi_c);
            W_v(A_v) := put(W_v(A_v), UnaryLimit_g, AdaptiveUnaryLimitLo_c, AdaptiveUnaryLimitHi_c);
        end if;
        -- BLOCK: block-adaptive coder
        A_v := RegBlock_c / 4;
        if Coder_c = CoderBlock_c then
            W_v(A_v) := put(W_v(A_v), RefInterval_g, BlockRefIntervalLo_c, BlockRefIntervalHi_c);
            W_v(A_v) := put(W_v(A_v), toInt(RestrictedCodes_g), BlockRestricted_c, BlockRestricted_c);
            W_v(A_v) := put(W_v(A_v), BlockSize_g, BlockBlockSizeLo_c, BlockBlockSizeHi_c);
        end if;
        return W_v;
    end function;

    constant Config_c : WordArr_t(0 to NumConfig_c - 1) := configWords;

    type CntArr_t is array (0 to NumCounters_c - 1) of unsigned(31 downto 0);

    -- Configuration of an image: NX, NY, NZ, absolute and relative error limit value
    type Cfg_r is record
        X    : unsigned(16 downto 0);
        Y    : unsigned(16 downto 0);
        Z    : unsigned(16 downto 0);
        AbsL : unsigned(15 downto 0);
        RelL : unsigned(15 downto 0);
    end record;

    constant CfgReset_c : Cfg_r := (X    => to_unsigned(XSize_g, 17), Y => to_unsigned(YSize_g, 17),
                                    Z    => to_unsigned(ZSize_g, 17), AbsL => to_unsigned(AbsConst_c, 16),
                                    RelL => to_unsigned(RelConst_c, 16));

    -- The values of a COMMIT are in range (MB-RC-02)
    function inRange (c : Cfg_r) return boolean is
        variable Ok_v : boolean;
    begin
        Ok_v := c.X >= 1 and c.X <= XSize_g and (c.X >= 2 or not Wide_c);
        Ok_v := Ok_v and c.Y >= 1 and c.Y <= YSize_g;
        Ok_v := Ok_v and c.Z >= 1 and c.Z <= ZSize_g;
        Ok_v := Ok_v and (not UseAbs_c or c.AbsL <= 2 ** AbsBitDepth_g - 1);
        Ok_v := Ok_v and (not UseRel_c or c.RelL <= 2 ** RelBitDepth_g - 1);
        return Ok_v;
    end function;

    type TwoProcess_r is record
        Cnt     : CntArr_t;
        RdData  : Word_t;
        RdValid : std_logic;
        -- Runtime configuration: pending set (NEXT_*), committed set (outputs to the core), STATUS
        Pend    : Cfg_r;
        Cfg     : Cfg_r;
        Pending : std_logic;
        Error   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Register bus of the AXI4-Lite slave
    signal RbAddr   : std_logic_vector(7 downto 0);
    signal RbWr     : std_logic;
    signal RbRd     : std_logic;
    signal RbByteEn : std_logic_vector(3 downto 0);
    signal RbWrData : std_logic_vector(31 downto 0);

    -- Bytes of a register write: the bytes with their byte enable from the write data, the others from the
    -- register
    function merge (
        old : std_logic_vector(31 downto 0);
        wr : std_logic_vector(31 downto 0);
        be : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable W_v : std_logic_vector(31 downto 0) := old;
    begin

        for b in 0 to 3 loop
            if be(b) = '1' then
                W_v(8 * b + 7 downto 8 * b) := wr(8 * b + 7 downto 8 * b);
            end if;
        end loop;

        return W_v;
    end function;

begin

    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable Ev_v  : std_logic_vector(0 to NumCounters_c - 1);
        variable Idx_v : natural range 0 to 63;
        variable W_v   : std_logic_vector(31 downto 0);
    begin
        v         := r;
        v.RdValid := '0';

        -- Counters in the order of the register map: a write clears a counter, an event of the same
        -- cycle counts after the clearing
        Ev_v  := Ev_ImageDone & Ev_ImageAborted & Ev_SduError & Ev_SduDiscarded & Ecc_Sec & Ecc_Ded;
        Idx_v := to_integer(unsigned(RbAddr(7 downto 2)));

        for i in 0 to NumCounters_c - 1 loop
            if RbWr = '1' and Idx_v = FirstCnt_c + i then
                v.Cnt(i) := (0 => Ev_v(i),
                             others => '0');
            elsif Ev_v(i) = '1' and r.Cnt(i) /= (r.Cnt(i)'range => '1') then
                v.Cnt(i) := r.Cnt(i) + 1;
            end if;
        end loop;

        -- Runtime configuration (MB-RC-01 to MB-RC-04): the pending registers take the written bytes; a
        -- COMMIT passes them to the configuration outputs in one clock cycle when every value is in range, else
        -- it sets CFG_ERROR; CFG_PENDING lasts from a valid COMMIT to the next Cfg_Taken (a COMMIT in the cycle of
        -- Cfg_Taken changes the outputs after the core took the previous values, CFG_PENDING stays set)
        if RuntimeConfig_g then
            if Cfg_Taken = '1' then
                v.Pending := '0';
            end if;
            if RbWr = '1' then
                if Idx_v = RegNextX_c / 4 then
                    W_v      := merge(std_logic_vector(resize(r.Pend.X, 32)), RbWrData, RbByteEn);
                    v.Pend.X := unsigned(W_v(NextXSizeHi_c downto NextXSizeLo_c));
                elsif Idx_v = RegNextY_c / 4 then
                    W_v      := merge(std_logic_vector(resize(r.Pend.Y, 32)), RbWrData, RbByteEn);
                    v.Pend.Y := unsigned(W_v(NextYSizeHi_c downto NextYSizeLo_c));
                elsif Idx_v = RegNextZ_c / 4 then
                    W_v      := merge(std_logic_vector(resize(r.Pend.Z, 32)), RbWrData, RbByteEn);
                    v.Pend.Z := unsigned(W_v(NextZSizeHi_c downto NextZSizeLo_c));
                elsif Idx_v = RegNextLimits_c / 4 then
                    W_v         := merge(std_logic_vector(r.Pend.RelL) & std_logic_vector(r.Pend.AbsL), RbWrData,
                                         RbByteEn);
                    v.Pend.AbsL := unsigned(W_v(NextLimitsAbsHi_c downto NextLimitsAbsLo_c));
                    v.Pend.RelL := unsigned(W_v(NextLimitsRelHi_c downto NextLimitsRelLo_c));
                elsif Idx_v = RegControl_c / 4 then
                    if RbByteEn(0) = '1' and RbWrData(ControlCommit_c) = '1' then
                        if inRange(r.Pend) then
                            v.Cfg     := r.Pend;
                            v.Pending := '1';
                        else
                            v.Error := '1';
                        end if;
                    end if;
                elsif Idx_v = RegStatus_c / 4 then
                    if RbByteEn(0) = '1' and RbWrData(StatusCfgError_c) = '1' then
                        v.Error := '0';
                    end if;
                end if;
            end if;
        end if;

        -- Reads are answered in the next clock cycle; unused addresses read zero
        if RbRd = '1' then
            v.RdValid := '1';
            v.RdData  := (others => '0');
            if Idx_v < NumConfig_c then
                v.RdData := Config_c(Idx_v);
            elsif Idx_v >= FirstCnt_c and Idx_v < FirstCnt_c + NumCounters_c then
                v.RdData := std_logic_vector(r.Cnt(Idx_v - FirstCnt_c));
            elsif Idx_v = RegLimits_c / 4 then
                v.RdData := put(put(Word_t'(others => '0'), AbsConst_c, LimitsAbsLo_c, LimitsAbsHi_c), RelConst_c,
                                LimitsRelLo_c, LimitsRelHi_c);
            end if;
            -- Runtime configuration: the values the core took for the last image, the pending set, STATUS
            if RuntimeConfig_g then
                if Idx_v = RegImageX_c / 4 then
                    v.RdData                                       := (others => '0');
                    v.RdData(ImageXSizeHi_c downto ImageXSizeLo_c) := Act_XSize;
                elsif Idx_v = RegImageY_c / 4 then
                    v.RdData                                       := (others => '0');
                    v.RdData(ImageYSizeHi_c downto ImageYSizeLo_c) := Act_YSize;
                elsif Idx_v = RegImageZ_c / 4 then
                    v.RdData                                       := (others => '0');
                    v.RdData(ImageZSizeHi_c downto ImageZSizeLo_c) := Act_ZSize;
                elsif Idx_v = RegOrder_c / 4 and Order_c = OrderBi_c then
                    if unsigned(Act_ZSize) < SubFrameDepth_g then
                        v.RdData(OrderSubFrameDepthHi_c downto OrderSubFrameDepthLo_c) := Act_ZSize;
                    end if;
                elsif Idx_v = RegLimits_c / 4 then
                    v.RdData(LimitsAbsHi_c downto LimitsAbsLo_c) := Act_AbsLimit;
                    v.RdData(LimitsRelHi_c downto LimitsRelLo_c) := Act_RelLimit;
                elsif Idx_v = RegNextX_c / 4 then
                    v.RdData(NextXSizeHi_c downto NextXSizeLo_c) := std_logic_vector(r.Pend.X);
                elsif Idx_v = RegNextY_c / 4 then
                    v.RdData(NextYSizeHi_c downto NextYSizeLo_c) := std_logic_vector(r.Pend.Y);
                elsif Idx_v = RegNextZ_c / 4 then
                    v.RdData(NextZSizeHi_c downto NextZSizeLo_c) := std_logic_vector(r.Pend.Z);
                elsif Idx_v = RegNextLimits_c / 4 then
                    v.RdData(NextLimitsAbsHi_c downto NextLimitsAbsLo_c) := std_logic_vector(r.Pend.AbsL);
                    v.RdData(NextLimitsRelHi_c downto NextLimitsRelLo_c) := std_logic_vector(r.Pend.RelL);
                elsif Idx_v = RegStatus_c / 4 then
                    v.RdData(StatusCfgPending_c) := r.Pending;
                    v.RdData(StatusCfgError_c)   := r.Error;
                end if;
            end if;
        end if;

        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Cnt     <= (others => (others => '0'));
                r.RdValid <= '0';
                if RuntimeConfig_g then
                    r.Pend    <= CfgReset_c;
                    r.Cfg     <= CfgReset_c;
                    r.Pending <= '0';
                    r.Error   <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Committed configuration (zero without the runtime configuration)
    g_runtime : if RuntimeConfig_g generate
        Cfg_XSize    <= std_logic_vector(r.Cfg.X);
        Cfg_YSize    <= std_logic_vector(r.Cfg.Y);
        Cfg_ZSize    <= std_logic_vector(r.Cfg.Z);
        Cfg_AbsLimit <= std_logic_vector(r.Cfg.AbsL);
        Cfg_RelLimit <= std_logic_vector(r.Cfg.RelL);
    end generate;

    g_constant : if not RuntimeConfig_g generate
        Cfg_XSize    <= (others => '0');
        Cfg_YSize    <= (others => '0');
        Cfg_ZSize    <= (others => '0');
        Cfg_AbsLimit <= (others => '0');
        Cfg_RelLimit <= (others => '0');
    end generate;

    i_axi : entity olo.olo_axi_lite_slave
        generic map (
            AxiAddrWidth_g => 8,
            AxiDataWidth_g => 32
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => S_AxiLite_ArAddr,
            S_AxiLite_ArValid => S_AxiLite_ArValid,
            S_AxiLite_ArReady => S_AxiLite_ArReady,
            S_AxiLite_AwAddr  => S_AxiLite_AwAddr,
            S_AxiLite_AwValid => S_AxiLite_AwValid,
            S_AxiLite_AwReady => S_AxiLite_AwReady,
            S_AxiLite_WData   => S_AxiLite_WData,
            S_AxiLite_WStrb   => S_AxiLite_WStrb,
            S_AxiLite_WValid  => S_AxiLite_WValid,
            S_AxiLite_WReady  => S_AxiLite_WReady,
            S_AxiLite_BResp   => S_AxiLite_BResp,
            S_AxiLite_BValid  => S_AxiLite_BValid,
            S_AxiLite_BReady  => S_AxiLite_BReady,
            S_AxiLite_RData   => S_AxiLite_RData,
            S_AxiLite_RResp   => S_AxiLite_RResp,
            S_AxiLite_RValid  => S_AxiLite_RValid,
            S_AxiLite_RReady  => S_AxiLite_RReady,
            Rb_Addr           => RbAddr,
            Rb_Wr             => RbWr,
            Rb_ByteEna        => RbByteEn,
            Rb_WrData         => RbWrData,
            Rb_Rd             => RbRd,
            Rb_RdData         => r.RdData,
            Rb_RdValid        => r.RdValid
        );

end architecture;
