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
        RefInterval_g          : positive range 1 to 4096  := 4096
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
        Ecc_Ded           : in    std_logic
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

    type TwoProcess_r is record
        Cnt     : CntArr_t;
        RdData  : Word_t;
        RdValid : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Register bus of the AXI4-Lite slave
    signal RbAddr : std_logic_vector(7 downto 0);
    signal RbWr   : std_logic;
    signal RbRd   : std_logic;

begin

    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable Ev_v  : std_logic_vector(0 to NumCounters_c - 1);
        variable Idx_v : natural range 0 to 63;
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

        -- Reads are answered in the next clock cycle; unused addresses read zero
        if RbRd = '1' then
            v.RdValid := '1';
            v.RdData  := (others => '0');
            if Idx_v < NumConfig_c then
                v.RdData := Config_c(Idx_v);
            elsif Idx_v >= FirstCnt_c and Idx_v < FirstCnt_c + NumCounters_c then
                v.RdData := std_logic_vector(r.Cnt(Idx_v - FirstCnt_c));
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
            end if;
        end if;
    end process;

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
            Rb_ByteEna        => open,
            Rb_WrData         => open,
            Rb_Rd             => RbRd,
            Rb_RdData         => r.RdData,
            Rb_RdValid        => r.RdValid
        );

end architecture;
