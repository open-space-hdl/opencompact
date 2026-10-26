---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Predictor, quantizer and mapper of CCSDS 123.0-B-2 (section 4): converts the image samples, given
-- in the input order of the compressed image (BI or BSQ, 5.4.2), into the entropy coder input
-- sequence (5.4.1) of mapped quantizer indices and, with periodic error limit updating, error limit
-- values.
--
-- The samples pass a pipeline without internal stalls. The issue stage starts a sample as soon as
-- the samples it depends on have left the feedback loops and the output FIFO has room for every
-- item in flight. The sign of the double-resolution prediction error, which drives the weight
-- update, follows from the dot product by comparisons with thresholds of the sample, so the weight
-- loop closes right after the dot product. When consecutive samples belong to the same band (BSQ,
-- BI with M = 1), the weight loop speculates: it keeps the weight vectors of all sign combinations
-- of the samples still in the loop and selects one as the signs become known. Sample
-- representatives, local differences and weights are kept in SECDED-protected memories.
--
-- Documentation: hdl/ocp_predictor/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_ft_pkg_ecc.all;

library work;
    use work.ocp_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_predictor is
    generic (
        -- Image
        XSize_g                : positive range 1 to 65536 := 8;
        YSize_g                : positive range 1 to 65536 := 8;
        ZSize_g                : positive range 1 to 65536 := 4;
        DynamicRange_g         : positive range 2 to 32    := 16;
        SignedSamples_g        : boolean                   := false;
        EncodingOrder_g        : string                    := "BI";
        SubFrameDepth_g        : positive range 1 to 65536 := 4;
        -- Predictor
        PredictionBands_g      : natural range 0 to 15     := 3;
        PredictionMode_g       : string                    := "FULL";
        LocalSum_g             : string                    := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive range 32 to 64   := 64;
        WeightResolution_g     : positive range 4 to 19    := 13;
        WeightUpdateInterval_g : positive range 4 to 11    := 6;
        WeightUpdateVmin_g     : integer range -6 to 9     := -1;
        WeightUpdateVmax_g     : integer range -6 to 9     := 3;
        WeightExpOffsetsUsed_g : boolean                   := false;
        WeightExpOffsets_g     : integer_vector            := (0 => 0);
        CustomWeights_g        : boolean                   := false;
        WeightInitResolution_g : natural range 0 to 22     := 0;
        WeightInitValues_g     : integer_vector            := (0 => 0);
        -- Quantizer
        Fidelity_g             : string                    := "LOSSLESS";
        PeriodicUpdate_g       : boolean                   := false;
        UpdatePeriodExp_g      : natural range 0 to 9      := 0;
        AbsBandDependent_g     : boolean                   := false;
        AbsErrorLimits_g       : integer_vector            := (0 => 0);
        RelBandDependent_g     : boolean                   := false;
        RelErrorLimits_g       : integer_vector            := (0 => 0);
        -- Sample representatives
        SampleRepResolution_g  : natural range 0 to 4      := 0;
        Damping_g              : integer_vector            := (0 => 0);
        Offset_g               : integer_vector            := (0 => 0);
        -- Implementation
        Speculation_g          : boolean                   := true;
        Stride_g               : boolean                   := true;
        RamStyle_g             : string                    := "auto";
        -- Image dimensions and band-independent error limit values of every image from the
        -- configuration inputs; XSize_g, YSize_g and ZSize_g are the maxima
        RuntimeConfig_g        : boolean                   := false;
        -- Runtime parameters (with RuntimeConfig_g): M (BI order, SubFrameDepth_g is the maximum) and the
        -- weight update parameters of every image from the configuration inputs
        RuntimeParams_g        : boolean                   := false
    );
    port (
        Clk                : in    std_logic;
        Rst                : in    std_logic;
        -- Image samples in the input order; In_End with a sample that ends its image early (the sample
        -- is the last item of the image, the next sample starts a new image)
        In_Valid           : in    std_logic;
        In_Ready           : out   std_logic;
        In_Data            : in    std_logic_vector(DynamicRange_g - 1 downto 0);
        In_End             : in    std_logic                     := '0';
        -- Error limit values for periodic error limit updating (entropy coder input order)
        Lim_Valid          : in    std_logic                     := '0';
        Lim_Ready          : out   std_logic;
        Lim_Data           : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Runtime configuration (RuntimeConfig_g): NX, NY, NZ (1 to the maxima) and the error limit
        -- values of the next image, taken with its first sample (Cfg_Take, a pulse in the clock cycle in
        -- which the first sample is accepted); while Cfg_Ready is '0' no first sample is accepted
        Cfg_Ready          : in    std_logic                     := '1';
        Cfg_XSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_YSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_ZSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_AbsLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        Cfg_RelLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Runtime parameters (RuntimeParams_g), taken with the configuration: M (1 to min(SubFrameDepth_g,
        -- NZ)), log2 t_inc (4 to 11), vmin and vmax (two's complement, -6 <= vmin <= vmax <= 9)
        Cfg_M              : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_WeightInterval : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_WeightVmin     : in    std_logic_vector(4 downto 0)  := (others => '0');
        Cfg_WeightVmax     : in    std_logic_vector(4 downto 0)  := (others => '0');
        Cfg_Take           : out   std_logic;
        -- Pulse: the first item (sample or error limit value) of an image is accepted
        Img_Start          : out   std_logic;
        -- Entropy coder input sequence
        Out_Valid          : out   std_logic;
        Out_Ready          : in    std_logic;
        Out_Data           : out   std_logic_vector(maximum(DynamicRange_g, 16) - 1 downto 0);
        Out_Kind           : out   std_logic_vector(1 downto 0);
        Out_Band           : out   std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
        Out_First          : out   std_logic;
        Out_Init           : out   std_logic;
        Out_Last           : out   std_logic;
        -- Memory errors (pulses): corrected single error, detected double error
        Ecc_Sec            : out   std_logic;
        Ecc_Ded            : out   std_logic;
        -- Error injection into the next write of memory ErrInj_Channel (0 to 11): a single (corrected)
        -- or a double (detected) bit error
        ErrInj_Channel     : in    std_logic_vector(3 downto 0)  := (others => '0');
        ErrInj_Double      : in    std_logic                     := '0';
        ErrInj_Valid       : in    std_logic                     := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_predictor is

    function sel (c : boolean; a : integer; b : integer) return integer is
    begin
        if c then
            return a;
        end if;
        return b;
    end function;

    -- Configuration
    constant D_c        : positive := DynamicRange_g;
    constant Om_c       : positive := WeightResolution_g;
    constant R_c        : positive := RegisterSize_g;
    constant P_c        : natural  := PredictionBands_g;
    constant Order_c    : natural  := encodingOrderCode(EncodingOrder_g);
    constant Bsq_c      : boolean  := Order_c = OrderBsq_c;
    constant Sum_c      : natural  := localSumCode(LocalSum_g);
    constant Narrow_c   : boolean  := Sum_c = SumNarrowNeighbor_c or Sum_c = SumNarrowColumn_c;
    constant Full_c     : boolean  := fullPrediction(PredictionMode_g);
    constant Fid_c      : natural  := fidelityCode(Fidelity_g);
    constant Lossless_c : boolean  := Fid_c = FidLossless_c;
    constant UseAbs_c   : boolean  := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
    constant UseRel_c   : boolean  := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
    constant Periodic_c : boolean  := PeriodicUpdate_g and not Lossless_c and not Bsq_c;
    constant Theta_c    : natural  := SampleRepResolution_g;

    function anyNonZero (v : integer_vector) return boolean is
    begin

        for i in v'range loop
            if v(i) /= 0 then
                return true;
            end if;
        end loop;

        return false;
    end function;

    -- The sample representatives are the samples in lossless compression without damping (4.9.2: with
    -- damping they depend on the high-resolution predicted sample also when m = 0)
    constant RepIsSample_c : boolean  := Lossless_c and (Theta_c = 0 or not anyNonZero(Damping_g));
    constant M_c           : positive := minimum(SubFrameDepth_g, ZSize_g);
    constant Cmax_c        : natural  := P_c + 3 * toInt(Full_c);
    constant C1_c          : positive := maximum(Cmax_c, 1);
    -- The sample representative of the previous sample of the band (W) enters the local sum or the
    -- directional local differences (CCSDS 4.4, 4.5.2)
    constant WUsed_c       : boolean := Full_c or not Narrow_c;
    -- Consecutive samples of a band follow each other directly, in BSQ and single-band images also
    -- from one row to the next
    constant Gap1_c        : boolean := Bsq_c or M_c = 1;
    constant RunRows_c     : boolean := Bsq_c or ZSize_g = 1;

    -- Widths: samples, local differences (and their storage), weights, dot product, high-resolution
    -- predicted sample, quantizer operands, sample representative numerator, sign comparison
    constant SW_c      : positive := D_c + 2;
    constant DW_c      : positive := D_c + 4;
    constant DWs_c     : positive := D_c + 3;
    constant WW_c      : positive := Om_c + 3;
    constant AccW_c    : positive := Om_c + D_c + 12;
    constant HW_c      : positive := maximum(R_c, AccW_c) + 3;
    constant STildeW_c : positive := Om_c + D_c + 6;
    constant QW_c      : positive := maximum(D_c, 16) + 2;
    constant RW_c      : positive := SW_c + Om_c + 12;
    constant OutW_c    : positive := maximum(D_c, 16);
    constant VW_c      : positive := maximum(R_c - Om_c - 1, maximum(D_c, 17) + 4);

    -- Counters
    constant XW_c : positive := log2ceil(XSize_g + 1);
    constant YW_c : positive := log2ceil(YSize_g + 1);
    constant ZW_c : positive := log2ceil(ZSize_g + 1);
    constant TW_c : positive := XW_c + YW_c + 1;

    -- Sample value limits (CCSDS 3.3.2)
    function sampleMin return signed is
    begin
        if SignedSamples_g then
            return shift_left(to_signed(-1, SW_c), D_c - 1);
        end if;
        return to_signed(0, SW_c);
    end function;

    function sampleMax return signed is
    begin
        if SignedSamples_g then
            return shift_left(to_signed(1, SW_c), D_c - 1) - 1;
        end if;
        return shift_left(to_signed(1, SW_c), D_c) - 1;
    end function;

    function sampleMid return signed is
    begin
        if SignedSamples_g then
            return to_signed(0, SW_c);
        end if;
        return shift_left(to_signed(1, SW_c), D_c - 1);
    end function;

    constant SMin_c : signed(SW_c - 1 downto 0) := sampleMin;
    constant SMax_c : signed(SW_c - 1 downto 0) := sampleMax;
    constant SMid_c : signed(SW_c - 1 downto 0) := sampleMid;

    -- Double-resolution predicted sample s~ = clip(V + 2 smid + 1, 2 smin, 2 smax + 1) with V the bits
    -- R - 1 to Omega + 1 of the wrapped high-resolution sum (4.7.2, 4.7.3); thresholds on V of the
    -- clip limits
    constant Lo_c  : signed(VW_c - 1 downto 0) := shift_left(resize(SMin_c, VW_c), 1);
    constant Hi_c  : signed(VW_c - 1 downto 0) := shift_left(resize(SMax_c, VW_c), 1) + 1;
    constant C0_c  : signed(VW_c - 1 downto 0) := shift_left(resize(SMid_c, VW_c), 1) + 1;
    constant TLo_c : signed(VW_c - 1 downto 0) := Lo_c - C0_c;
    constant THi_c : signed(VW_c - 1 downto 0) := Hi_c - C0_c;

    -- Pipeline stages: stage k computes the pipeline register P(k) from P(k - 1); the issue stage
    -- (0) addresses the memories, whose read data the stage StRam_c uses
    function treeStages (n : positive) return positive is
        variable Stages_v : positive := 1;
        variable Reach_v  : positive := 4;
    begin

        while Reach_v < n loop
            Reach_v  := Reach_v * 4;
            Stages_v := Stages_v + 1;
        end loop;

        return Stages_v;
    end function;

    -- Operands of the adder tree: the products and the local sum term 2^Omega (sigma - 4 smid)
    constant Nops_c       : positive := C1_c + 1;
    constant TreeSt_c     : positive := treeStages(Nops_c);
    -- The sign of the prediction error follows from the dot product unless relative error limits make
    -- the maximum error depend on the prediction (4.8.2)
    constant ThreshSign_c : boolean := not UseRel_c;
    -- Speculation over the signs of the two previous samples of the band: four weight vectors
    constant Spec_c       : boolean  := Speculation_g and ThreshSign_c and Gap1_c and Cmax_c > 0 and TreeSt_c = 1 and
                                       (RepIsSample_c or not WUsed_c);
    constant NC_c         : positive := sel(Spec_c, 4, 1);

    constant StRam_c    : natural  := 2;                      -- memory data, local sum
    constant StDiff_c   : natural  := 3;                      -- local differences
    constant StInc_c    : natural  := 4;                      -- weight increments, sign thresholds
    constant StProd_c   : natural  := 5;                      -- products of the dot product
    constant StTree_c   : natural  := StProd_c + TreeSt_c;    -- high-resolution sum
    constant StSgn_c    : natural  := StTree_c + 1;           -- error sign, high-resolution predicted sample
    constant StPredB_c  : natural  := StSgn_c + 1;            -- double-resolution predicted sample
    constant StQuant_c  : natural  := StPredB_c + 1;          -- prediction residual
    constant StLimit_c  : natural  := StQuant_c + 1;          -- maximum error, dividends
    constant StUpd_c    : natural  := sel(ThreshSign_c, StSgn_c, StLimit_c) + 1; -- updated weights
    constant DivSt_c    : natural  := QW_c * toInt(not Lossless_c);
    constant StRep_c    : natural  := StLimit_c + DivSt_c + 1; -- quantizer index, clipped bin center
    constant StRepMul_c : natural  := StRep_c + 1;            -- mapped index, representative products
    constant StRepSum_c : natural  := StRepMul_c + 1;         -- sample representative
    constant StOut_c    : natural  := maximum(StRepSum_c, StUpd_c);
    constant NSt_c      : positive := StOut_c + 1;
    -- Stage that provides the central local difference to the next band: at once when the sample
    -- representatives are the samples, otherwise with the sample representative
    constant StDz_c     : natural := sel(RepIsSample_c, StDiff_c, StRepSum_c);

    -- Memories: sample representatives of the current line of every band (BI) or of row 0 of the
    -- current and the previous band and the current line (BSQ); window of the previous line, previous
    -- sample and first sample of the line per band; central local differences of the previous bands
    -- per pixel; weight vectors per band
    constant BandSlots_c : positive := sel(Bsq_c, 2, maximum(ZSize_g, 2));
    constant SrDepth_c   : positive := maximum(sel(Bsq_c, 3 * XSize_g, ZSize_g * XSize_g), 2);
    constant DiffRam_c   : boolean  := P_c > 0 and (Bsq_c or M_c < ZSize_g or (RuntimeParams_g and ZSize_g > 1));
    constant DiffDepth_c : positive := maximum(sel(Bsq_c, XSize_g * YSize_g, XSize_g), 2);
    constant DiffBits_c  : positive := maximum(P_c, 1) * DWs_c;
    constant WBits_c     : positive := C1_c * WW_c;
    constant WRam_c      : boolean  := Cmax_c > 0 and not (Spec_c and RunRows_c);

    -- Distances (cycles) between dependent samples at the issue stage
    -- * Same band: weights (read at stage 3, written from P(StUpd_c)) unless the speculation continues
    --   the run of the band, window of the previous line (written from P(StRam_c)) unless forwarded,
    --   in near-lossless compression the sample representatives of the previous sample and of the
    --   previous line (written from P(StRepSum_c))
    -- * Previous band at the same pixel (or at x - 1 in row 0 with narrow local sums): central local
    --   differences (from P(StDz_c)) and, in near-lossless compression, the sample representatives
    -- The distances that depend on the image dimensions (window, sample representatives of the previous row,
    -- central local differences of the previous sub-frame or band) come from issueDist: during the elaboration for
    -- constant dimensions, from the image-start sequencer for runtime dimensions (ocp_image_start)
    constant Lw_c        : natural     := sel(Cmax_c > 0, StUpd_c - 1, 0);
    constant LwinMem_c   : natural     := StRam_c + 2;
    constant Lrep_c      : natural     := StRepSum_c + 2;
    constant Ldw_c       : natural     := StDz_c + 2;
    constant CrossRep_c  : boolean     := not RepIsSample_c and (P_c > 0 or Narrow_c);
    constant Dist_c      : IssueDist_r := issueDist(Bsq_c, SubFrameDepth_g, XSize_g, YSize_g, ZSize_g, P_c,
                                                   RepIsSample_c, WUsed_c, CrossRep_c, LwinMem_c, Lrep_c, Ldw_c);
    constant Lfix_c      : natural     := Dist_c.LFix;
    constant Lcross_c    : natural     := Dist_c.LCross;
    -- Largest distances over the dimensions up to the maxima (runtime configuration)
    constant LfixMax_c   : natural  := maximum(sel(Gap1_c, 0, LwinMem_c), sel(RepIsSample_c, 0, Lrep_c));
    constant LcrossMax_c : natural  := maximum(sel(CrossRep_c, Lrep_c, 0), sel(DiffRam_c, Ldw_c, 0));
    constant SbLen_c     : positive := maximum(maximum(maximum(Lw_c, sel(RuntimeConfig_g, LfixMax_c, Lfix_c)),
                                                       sel(RuntimeConfig_g, LcrossMax_c, Lcross_c)) - 1, 1);

    -- Output FIFO: room for every item in flight
    constant FifoDepth_c : positive := 2 ** log2ceil(NSt_c + 8);
    constant FifoW_c     : positive := OutW_c + 2 + ZW_c + 3;

    -- Stride order (BI order with M = NZ, near-lossless compression with dependencies between the bands
    -- of a pixel): sample (z, t) of an image is processed in slot t M + z S. With S >= Lcross_c and
    -- coprime with M the sample of the previous band at the same pixel is S slots ahead, the previous
    -- sample of the band M slots. An input buffer delays band z by z (S - 1) slots, an output buffer
    -- restores the input order. Not with the runtime configuration (PR-RC-04).
    constant Stride_c : boolean := Stride_g and not Bsq_c and M_c = ZSize_g and ZSize_g > 1 and CrossRep_c and
                                   not Periodic_c and not RuntimeConfig_g;

    function gcd (a : positive; b : positive) return positive is
        variable A_v : natural := a;
        variable B_v : natural := b;
        variable T_v : natural;
    begin

        while B_v /= 0 loop
            T_v := A_v mod B_v;
            A_v := B_v;
            B_v := T_v;
        end loop;

        return A_v;
    end function;

    function strideOf return positive is
        variable S_v : positive := maximum(Lcross_c, 2);
    begin

        while gcd(S_v, M_c) /= 1 loop
            S_v := S_v + 1;
        end loop;

        return S_v;
    end function;

    constant S_c : positive := strideOf;

    -- Inverse of S modulo M: the slot after slot n holds band z + Sinv (mod M)
    function invMod return natural is
    begin

        for i in 1 to M_c - 1 loop
            if (S_c * i) mod M_c = 1 then
                return i;
            end if;
        end loop;

        return 0;
    end function;

    constant Sinv_c     : natural := invMod;
    -- S Sinv = 1 + SJ M: from slot n to n + 1 the pixel index changes by S - SJ (band wrap) or by -SJ
    constant SJ_c       : natural := sel(Stride_c, (S_c * Sinv_c - 1) / M_c, 0);
    constant DtWrap_c   : integer := S_c - SJ_c;
    constant DtNoWrap_c : integer := -SJ_c;
    constant DaWrap_c   : integer := DtWrap_c * M_c + Sinv_c - M_c;
    constant DaNoWrap_c : integer := DtNoWrap_c * M_c + Sinv_c;
    -- Column changes of a slot step: multiples k of NX from KMin_c to KMax_c
    constant KMin_c     : integer := -((SJ_c + XSize_g - 1) / XSize_g);
    constant KMax_c     : integer := (XSize_g - 1 + S_c) / XSize_g;
    -- Indexes: arrival index within an image, slot index; buffers
    constant Skew_c     : natural                     := (M_c - 1) * (S_c - 1);
    constant AW_c       : positive                    := TW_c + ZW_c + 1;
    constant SlW_c      : positive                    := AW_c + log2ceil(S_c + 1) + 1;
    constant InDepth_c  : positive                    := 2 ** log2ceil(Skew_c + M_c + 8);
    constant OutDepth_c : positive                    := 2 ** log2ceil(Skew_c + 2 * NSt_c + 16);
    constant NPix_c     : unsigned(TW_c - 1 downto 0) := resize(to_unsigned(XSize_g, XW_c) * to_unsigned(YSize_g, YW_c),
                                                               TW_c);
    constant NArr_c     : unsigned(AW_c - 1 downto 0) := resize(NPix_c * to_unsigned(M_c, ZW_c), AW_c);
    -- Local differences per band and pixel: band z - 1 may run up to floor(S / M) pixels ahead of band z
    -- (stride order only)
    constant KCtx_c     : positive := sel(Stride_c, 2 ** log2ceil(S_c / M_c + 1), 1);
    constant CtxDepth_c : positive := BandSlots_c * KCtx_c;

    -- Fully constrained array types: a record field is never an index constraint on an unconstrained array type,
    -- whose element some simulators give a wrong constraint when the record is accessed through an alias
    type DiffArr_t is array (0 to C1_c - 1) of signed(DW_c - 1 downto 0);
    type WeightArr_t is array (0 to C1_c - 1) of signed(WW_c - 1 downto 0);
    type WeightSet_t is array (0 to NC_c - 1) of WeightArr_t;
    type IncArr_t is array (0 to C1_c - 1) of signed(WW_c + 1 downto 0);
    type ZetaArr_t is array (0 to C1_c - 1) of signed(3 downto 0);
    type PartArr_t is array (0 to Nops_c - 1) of signed(AccW_c - 1 downto 0);
    type PartSet_t is array (0 to NC_c - 1) of PartArr_t;
    type QuoArr_t is array (0 to 2) of unsigned(QW_c - 1 downto 0);
    type RemArr_t is array (0 to 2) of unsigned(18 downto 0);

    -- Initial weight vector W_z(1) of band z (CCSDS 4.6.3)
    function initWeights (z : natural) return WeightArr_t is
        variable W_v     : WeightArr_t := (others => (others => '0'));
        variable Pz_v    : natural;
        variable Cur_v   : integer;
        variable Base_v  : natural;
        variable Rem_v   : integer;
        variable Low_v   : integer;
        variable First_v : natural;
    begin
        Pz_v := bandsUsed(z, P_c);
        if CustomWeights_g then
            -- (35): Q MSBs from the weight initialization vector, then '0' and '1' bits
            Base_v := bandTableStart(z, P_c, 3 * toInt(Full_c));
            Rem_v  := Om_c + 3 - WeightInitResolution_g;
            Low_v  := 0;
            if Rem_v >= 1 then
                Low_v := 2 ** (Rem_v - 1) - 1;
            end if;

            for j in 0 to diffsUsed(z, P_c, Full_c) - 1 loop
                W_v(j) := shift_left(to_signed(vecElem(WeightInitValues_g, Base_v + j), WW_c), Rem_v) +
                          to_signed(Low_v, WW_c);
            end loop;

        else
            -- (33), (34): directional weights 0, inter-band weights 7/8 2^Omega, then 1/8 of the previous
            First_v := 3 * toInt(Full_c);
            if Pz_v > 0 then
                Cur_v        := 7 * 2 ** (Om_c - 3);
                W_v(First_v) := to_signed(Cur_v, WW_c);

                for i in 2 to Pz_v loop
                    Cur_v                := Cur_v / 8;
                    W_v(First_v + i - 1) := to_signed(Cur_v, WW_c);
                end loop;

            end if;
        end if;
        return W_v;
    end function;

    -- Weight exponent offset of component j in band z (CCSDS 4.10.4)
    function expOffset (z : natural; j : natural) return integer is
        variable Base_v : natural;
        variable Idx_v  : integer;
    begin
        if not WeightExpOffsetsUsed_g then
            return 0;
        end if;
        Base_v := bandTableStart(z, P_c, toInt(Full_c));
        if Full_c then
            if j < 3 then
                Idx_v := 0;
            else
                Idx_v := j - 2;
            end if;
        else
            Idx_v := j;
        end if;
        if Idx_v > bandsUsed(z, P_c) - 1 + toInt(Full_c) then
            return 0;
        end if;
        return vecElem(WeightExpOffsets_g, Base_v + Idx_v);
    end function;

    -- Per-band tables as ROMs
    type IntRom_t is array (0 to ZSize_g - 1) of integer;
    type WeightRom_t is array (0 to ZSize_g - 1) of std_logic_vector(WBits_c - 1 downto 0);
    type ZetaRom_t is array (0 to ZSize_g - 1) of std_logic_vector(C1_c * 4 - 1 downto 0);

    function tableRom (v : integer_vector) return IntRom_t is
        variable R_v : IntRom_t;
    begin

        for z in 0 to ZSize_g - 1 loop
            R_v(z) := vecElem(v, z);
        end loop;

        return R_v;
    end function;

    function weightRom return WeightRom_t is
        variable R_v : WeightRom_t;
        variable W_v : WeightArr_t;
    begin

        for z in 0 to ZSize_g - 1 loop
            W_v := initWeights(z);

            for j in W_v'range loop
                R_v(z)((j + 1) * WW_c - 1 downto j * WW_c) := std_logic_vector(W_v(j));
            end loop;

        end loop;

        return R_v;
    end function;

    function zetaRom return ZetaRom_t is
        variable R_v : ZetaRom_t;
    begin

        for z in 0 to ZSize_g - 1 loop

            for j in 0 to C1_c - 1 loop
                R_v(z)((j + 1) * 4 - 1 downto j * 4) := std_logic_vector(to_signed(expOffset(z, j), 4));
            end loop;

        end loop;

        return R_v;
    end function;

    constant AbsRom_c    : IntRom_t    := tableRom(AbsErrorLimits_g);
    constant RelRom_c    : IntRom_t    := tableRom(RelErrorLimits_g);
    constant PhiRom_c    : IntRom_t    := tableRom(Damping_g);
    constant PsiRom_c    : IntRom_t    := tableRom(Offset_g);
    constant WeightRom_c : WeightRom_t := weightRom;
    constant ZetaRom_c   : ZetaRom_t   := zetaRom;

    -- Conversions between the stored sample format (D bits) and the internal signed format
    function toSample (d : std_logic_vector) return signed is
    begin
        if SignedSamples_g then
            return resize(signed(d), SW_c);
        end if;
        return signed(resize(unsigned(d), SW_c));
    end function;

    function clipSigned (x : signed; lo : signed; hi : signed) return signed is
    begin
        if x < lo then
            return resize(lo, x'length);
        elsif x > hi then
            return resize(hi, x'length);
        end if;
        return x;
    end function;

    -- One stage of the adder tree: sums of four operands
    function reduce4 (p : PartArr_t) return PartArr_t is
        variable R_v : PartArr_t := (others => (others => '0'));
        variable A_v : signed(AccW_c - 1 downto 0);
        variable B_v : signed(AccW_c - 1 downto 0);
    begin

        for i in 0 to (p'length + 3) / 4 - 1 loop
            A_v := p(4 * i);
            B_v := (others => '0');
            if 4 * i + 1 < p'length then
                A_v := A_v + p(4 * i + 1);
            end if;
            if 4 * i + 2 < p'length then
                B_v := p(4 * i + 2);
            end if;
            if 4 * i + 3 < p'length then
                B_v := B_v + p(4 * i + 3);
            end if;
            R_v(i) := A_v + B_v;
        end loop;

        return R_v;
    end function;

    -- Weight increment (4.10.3) for the local difference u, error sign sgn+ and shift
    -- rho + zeta + D - Omega
    function weightInc (u : signed; plus : std_logic; shift : integer) return signed is
        variable Val_v : signed(DW_c downto 0);
        variable Big_v : signed(DW_c + WW_c + 4 downto 0);
        variable Sat_v : boolean;
    begin
        Val_v := resize(u, DW_c + 1);
        if plus = '0' then
            Val_v := -Val_v;
        end if;
        Sat_v := false;
        Big_v := (others => '0');
        if shift >= DW_c then
            -- floor((v + 2^s) / 2^(s+1)) is zero once 2^s exceeds |v|
            Big_v := (others => '0');
        elsif shift >= 0 then
            Big_v := resize(Val_v, Big_v'length) + shift_left(to_signed(1, Big_v'length), shift);
            Big_v := shift_right(Big_v, shift + 1);
        elsif -shift - 1 > WW_c + 1 then
            -- floor((v 2^(-s) + 1) / 2) = v 2^(-s-1), beyond the weight range unless v = 0
            Sat_v := Val_v /= 0;
        else
            Big_v := shift_left(resize(Val_v, Big_v'length), -shift - 1);
        end if;
        -- Saturation: an increment beyond the weight range is clipped with the weight anyway
        if (Sat_v and Val_v > 0) or Big_v > shift_left(to_signed(1, Big_v'length), WW_c) then
            return shift_left(to_signed(1, WW_c + 2), WW_c);
        elsif (Sat_v and Val_v < 0) or Big_v < -shift_left(to_signed(1, Big_v'length), WW_c) then
            return -shift_left(to_signed(1, WW_c + 2), WW_c);
        end if;
        return resize(Big_v, WW_c + 2);
    end function;

    -- Weight plus increment, clipped to the weight range (4.10.3)
    function weightAdd (w : signed; inc : signed) return signed is
        variable Wn_v : signed(WW_c + 2 downto 0);
    begin
        Wn_v := resize(w, Wn_v'length) + inc;
        Wn_v := clipSigned(Wn_v, -shift_left(to_signed(1, Wn_v'length), Om_c + 2),
                           shift_left(to_signed(1, Wn_v'length), Om_c + 2) - 1);
        return resize(Wn_v, WW_c);
    end function;

    -- Item in the pipeline: mapped quantizer index of a sample or error limit value
    type Item_r is record
        Valid    : std_logic;
        Kind     : std_logic_vector(1 downto 0);
        LimVal   : unsigned(15 downto 0);
        -- Position and flags
        X        : unsigned(XW_c - 1 downto 0);
        Y        : unsigned(YW_c - 1 downto 0);
        Z        : unsigned(ZW_c - 1 downto 0);
        T        : unsigned(TW_c - 1 downto 0);
        First    : std_logic;
        Init     : std_logic;
        Last     : std_logic;
        SubFirst : std_logic;
        SubLast  : std_logic;
        -- Sample and neighbors
        Sample   : signed(SW_c - 1 downto 0);
        Alt      : signed(SW_c - 1 downto 0);
        NE       : signed(SW_c - 1 downto 0);
        N        : signed(SW_c - 1 downto 0);
        NW       : signed(SW_c - 1 downto 0);
        W        : signed(SW_c - 1 downto 0);
        -- Band parameters
        Zeta     : ZetaArr_t;
        AbsLim   : unsigned(15 downto 0);
        RelLim   : unsigned(15 downto 0);
        Phi      : natural range 0 to 15;
        Psi      : natural range 0 to 15;
        Rho      : integer range -64 to 63;
        -- Local sum, local differences
        Sigma    : signed(SW_c + 2 downto 0);
        U        : DiffArr_t;
        Ctx      : std_logic_vector(DiffBits_c - 1 downto 0);
        Dz       : signed(DW_c - 1 downto 0);
        -- Weight loop: increments for both error signs, sign thresholds, candidate weight vectors and
        -- their high-resolution sums, error sign, selected weights
        IncP     : IncArr_t;
        IncN     : IncArr_t;
        T1       : signed(VW_c - 1 downto 0);
        T2       : signed(VW_c - 1 downto 0);
        ANever   : std_logic;
        AAlways  : std_logic;
        BAlways  : std_logic;
        BNever   : std_logic;
        WCand    : WeightSet_t;
        Part     : PartSet_t;
        SgnPlus  : std_logic;
        Wgt      : WeightArr_t;
        -- Prediction
        ModV     : signed(HW_c - 1 downto 0);
        STilde   : signed(STildeW_c - 1 downto 0);
        SDbl     : signed(SW_c downto 0);
        SHat     : signed(SW_c - 1 downto 0);
        Res      : signed(SW_c downto 0);
        RelProd  : unsigned(SW_c + 16 downto 0);
        -- Quantization
        M        : unsigned(15 downto 0);
        Divisor  : unsigned(17 downto 0);
        Dvd      : QuoArr_t;
        Quo      : QuoArr_t;
        Remd     : RemArr_t;
        -- Reconstruction and mapping
        Q        : signed(QW_c downto 0);
        ThetaM   : unsigned(QW_c - 1 downto 0);
        SClip    : signed(SW_c - 1 downto 0);
        Corr     : signed(RW_c - 1 downto 0);
        Num1     : signed(RW_c - 1 downto 0);
        Num2     : signed(RW_c - 1 downto 0);
        SRep     : signed(SW_c - 1 downto 0);
        Delta    : unsigned(D_c - 1 downto 0);
        -- Stride order: index of the sample in the input order of the image, slot
        ArrIdx   : unsigned(AW_c - 1 downto 0);
        SlotIdx  : unsigned(SlW_c - 1 downto 0);
        -- Runtime configuration: NX of the image, last column, run of the band across rows
        Nx       : unsigned(XW_c - 1 downto 0);
        XLast    : std_logic;
        RunRows  : std_logic;
        -- Runtime parameters: log2 t_inc, vmin and vmax of the image (no bits without them)
        TInc     : natural range 0 to 15 * toInt(RuntimeParams_g);
        Vmin     : integer range -16 * toInt(RuntimeParams_g) to 15 * toInt(RuntimeParams_g);
        Vmax     : integer range -16 * toInt(RuntimeParams_g) to 15 * toInt(RuntimeParams_g);
    end record;

    type ItemArr_t is array (0 to NSt_c - 1) of Item_r;

    type SbEntry_r is record
        Valid : std_logic;
        Band  : unsigned(ZW_c - 1 downto 0);
        X     : unsigned(XW_c - 1 downto 0);
    end record;

    type SbArr_t is array (1 to SbLen_c) of SbEntry_r;

    type TwoProcess_r is record
        P        : ItemArr_t;
        -- Position of the next item in the input order
        X        : unsigned(XW_c - 1 downto 0);
        Y        : unsigned(YW_c - 1 downto 0);
        Z        : unsigned(ZW_c - 1 downto 0);
        SubLow   : unsigned(ZW_c - 1 downto 0);
        RowBase  : unsigned(TW_c - 1 downto 0);
        LimDone  : std_logic;
        LimIdx   : natural range 0 to 2 * ZSize_g;
        ImgFresh : std_logic;
        AbsConst : unsigned(15 downto 0);
        RelConst : unsigned(15 downto 0);
        -- Sample of the previous band at t = 0, central local differences of the previous sample,
        -- window of the previous line of the last sample at the stage StRam_c
        LastT0   : signed(SW_c - 1 downto 0);
        LastWord : std_logic_vector(DiffBits_c - 1 downto 0);
        WinValid : std_logic;
        WinBand  : unsigned(ZW_c - 1 downto 0);
        WinN     : signed(SW_c - 1 downto 0);
        WinNE    : signed(SW_c - 1 downto 0);
        -- Speculative weight loop: weight vectors of the next sample for the four combinations of the
        -- error signs of the two previous samples, signs of the last two samples at the stage StSgn_c
        CW       : WeightSet_t;
        S1       : std_logic;
        S2       : std_logic;
        -- Bands issued in the last cycles, items in flight
        Sb       : SbArr_t;
        Inflight : natural range 0 to NSt_c + 1;
        EccSec   : std_logic;
        EccDed   : std_logic;
        -- Stride order: samples of the image accepted, smallest input index of an unprocessed sample
        -- (bound), current slot (band, pixel index, column, row, input index, slot index), all slots
        -- of the image processed; output: next input index (band, slot), slot of the last finished
        -- sample, reads in flight
        ArrIn    : unsigned(AW_c - 1 downto 0);
        LowA     : unsigned(AW_c - 1 downto 0);
        SZ       : unsigned(ZW_c - 1 downto 0);
        ST       : signed(SlW_c downto 0);
        SX       : unsigned(XW_c - 1 downto 0);
        SY       : signed(SlW_c downto 0);
        SA       : signed(SlW_c downto 0);
        SSlot    : unsigned(SlW_c - 1 downto 0);
        PDone    : std_logic;
        OA       : unsigned(AW_c - 1 downto 0);
        OZ       : unsigned(ZW_c - 1 downto 0);
        OSlot    : unsigned(SlW_c - 1 downto 0);
        DoneSlot : unsigned(SlW_c - 1 downto 0);
        DoneOk   : std_logic;
        ORd      : std_logic_vector(1 to 2);
        OBand1   : unsigned(ZW_c - 1 downto 0);
        OBand2   : unsigned(ZW_c - 1 downto 0);
        OFlags1  : std_logic_vector(2 downto 0);
        OFlags2  : std_logic_vector(2 downto 0);
        -- Stride order, early end: input index of the sample with In_End, samples issued in the image
        EndV     : std_logic;
        EndA     : unsigned(AW_c - 1 downto 0);
        IssCnt   : unsigned(AW_c - 1 downto 0);
        -- Runtime configuration: first sample of the image held while the image-start sequencer runs,
        -- dimensions of the image at the issue stage (NX, the last index of every dimension, M and M - 1),
        -- its issue conditions
        Hold     : std_logic;
        HoldData : std_logic_vector(D_c - 1 downto 0);
        HoldEnd  : std_logic;
        SeqBusy  : std_logic;
        CurNx    : unsigned(XW_c - 1 downto 0);
        CurXMax  : unsigned(XW_c - 1 downto 0);
        CurYMax  : unsigned(YW_c - 1 downto 0);
        CurZMax  : unsigned(ZW_c - 1 downto 0);
        CurM     : unsigned(ZW_c - 1 downto 0);
        CurMm1   : unsigned(ZW_c - 1 downto 0);
        LFix     : natural range 0 to 255;
        LCross   : natural range 0 to 255;
        RunRows  : std_logic;
        -- Runtime parameters of the image at the issue stage (no bits without them)
        CurTInc  : natural range 0 to 15 * toInt(RuntimeParams_g);
        CurVmin  : integer range -16 * toInt(RuntimeParams_g) to 15 * toInt(RuntimeParams_g);
        CurVmax  : integer range -16 * toInt(RuntimeParams_g) to 15 * toInt(RuntimeParams_g);
    end record;

    signal r, r_next : TwoProcess_r;

    -- Memory ports
    signal SrRdAddr    : std_logic_vector(log2ceil(SrDepth_c) - 1 downto 0);
    signal SrRdData    : std_logic_vector(D_c - 1 downto 0);
    signal SrWrAddr    : std_logic_vector(log2ceil(SrDepth_c) - 1 downto 0);
    signal SrWrEna     : std_logic;
    signal SrWrData    : std_logic_vector(D_c - 1 downto 0);
    signal BandRdAddr  : std_logic_vector(log2ceil(BandSlots_c) - 1 downto 0);
    signal WinWrAddr   : std_logic_vector(log2ceil(BandSlots_c) - 1 downto 0);
    signal WinWrEna    : std_logic;
    signal WinWrData   : std_logic_vector(2 * D_c - 1 downto 0);
    signal WinRdData   : std_logic_vector(2 * D_c - 1 downto 0);
    signal RepWrAddr   : std_logic_vector(log2ceil(BandSlots_c) - 1 downto 0);
    signal RepWrEna    : std_logic;
    signal RowWrEna    : std_logic;
    signal RepWrData   : std_logic_vector(D_c - 1 downto 0);
    signal RepRdData   : std_logic_vector(D_c - 1 downto 0);
    signal RowRdData   : std_logic_vector(D_c - 1 downto 0);
    signal DiffRdAddr  : std_logic_vector(log2ceil(DiffDepth_c) - 1 downto 0);
    signal DiffWrAddr  : std_logic_vector(log2ceil(DiffDepth_c) - 1 downto 0);
    signal DiffRdData  : std_logic_vector(DiffBits_c - 1 downto 0);
    signal DiffWrEna   : std_logic;
    signal DiffWrData  : std_logic_vector(DiffBits_c - 1 downto 0);
    signal WRdAddr     : std_logic_vector(log2ceil(BandSlots_c) - 1 downto 0);
    signal WWrAddr     : std_logic_vector(log2ceil(BandSlots_c) - 1 downto 0);
    signal WRdData     : std_logic_vector(WBits_c - 1 downto 0);
    signal WWrEna      : std_logic;
    signal WWrData     : std_logic_vector(WBits_c - 1 downto 0);
    signal LimRdAddr   : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
    signal LimWrAddr   : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
    signal AbsWrEna    : std_logic;
    signal RelWrEna    : std_logic;
    signal AbsRdData   : std_logic_vector(15 downto 0);
    signal RelRdData   : std_logic_vector(15 downto 0);
    signal FifoInValid : std_logic;
    signal FifoInData  : std_logic_vector(FifoW_c - 1 downto 0);
    signal FifoLevel   : std_logic_vector(log2ceil(FifoDepth_c + 1) - 1 downto 0);
    signal FifoOutData : std_logic_vector(FifoW_c - 1 downto 0);
    signal FifoOutVld  : std_logic;
    signal FifoOutRdy  : std_logic;
    signal OutData     : std_logic_vector(FifoW_c - 1 downto 0);
    signal EccSecVec   : std_logic_vector(11 downto 0);
    signal InjVec      : std_logic_vector(11 downto 0);
    signal EccDedVec   : std_logic_vector(11 downto 0);
    -- Stride order: input buffer, output buffer, central local differences per band
    signal InWrEna     : std_logic;
    signal InWrAddr    : std_logic_vector(log2ceil(InDepth_c) - 1 downto 0);
    signal InRdAddr    : std_logic_vector(log2ceil(InDepth_c) - 1 downto 0);
    signal InRdData    : std_logic_vector(D_c - 1 downto 0);
    signal OutWrEna    : std_logic;
    signal OutWrAddr   : std_logic_vector(log2ceil(OutDepth_c) - 1 downto 0);
    signal OutWrData   : std_logic_vector(D_c - 1 downto 0);
    signal OutRdAddr   : std_logic_vector(log2ceil(OutDepth_c) - 1 downto 0);
    signal OutRdData   : std_logic_vector(D_c - 1 downto 0);
    signal CtxWrEna    : std_logic;
    signal CtxWrAddr   : std_logic_vector(log2ceil(CtxDepth_c) - 1 downto 0);
    signal CtxRdAddr   : std_logic_vector(log2ceil(CtxDepth_c) - 1 downto 0);
    signal CtxRdData   : std_logic_vector(DiffBits_c - 1 downto 0);
    signal CtxWrData   : std_logic_vector(DiffBits_c - 1 downto 0);
    -- Image-start sequencer (runtime configuration)
    signal SeqStart    : std_logic;
    signal SeqDone     : std_logic;
    signal SeqM        : std_logic_vector(16 downto 0);
    signal SeqRunRows  : std_logic;
    signal SeqLFix     : std_logic_vector(7 downto 0);
    signal SeqLCross   : std_logic_vector(7 downto 0);

    -- Address of the sample representative of band z, column x, in row 0 or a later row: BI keeps
    -- the current line of every band, BSQ row 0 of the current and the previous band and the line
    function srAddr (z : unsigned; row0 : boolean; x : natural) return std_logic_vector is
        variable Slot_v : natural;
    begin
        if Bsq_c then
            if row0 then
                Slot_v := to_integer(z(0 downto 0));
            else
                Slot_v := 2;
            end if;
        else
            Slot_v := to_integer(z);
        end if;
        return std_logic_vector(to_unsigned(Slot_v * XSize_g + x, SrRdAddr'length));
    end function;

    function bandAddr (z : unsigned) return std_logic_vector is
    begin
        if Bsq_c then
            return std_logic_vector(to_unsigned(0, log2ceil(BandSlots_c)));
        end if;
        return std_logic_vector(resize(z, log2ceil(BandSlots_c)));
    end function;

    -- Entry of band z at pixel t in the memory of local differences of the stride order
    function ctxAddr (z : unsigned; t : unsigned) return std_logic_vector is
        variable A_v : unsigned(log2ceil(CtxDepth_c) - 1 downto 0);
    begin
        A_v := shift_left(resize(z, A_v'length), log2ceil(KCtx_c));
        if KCtx_c > 1 then
            -- t mod KCtx (t may have fewer bits than KCtx needs in small images)
            A_v := A_v or resize(resize(t, log2ceil(KCtx_c)), A_v'length);
        end if;
        return std_logic_vector(A_v);
    end function;

    -- Central local differences of the previous bands, shifted by the difference of band z
    function shiftCtx (ctx : std_logic_vector; dz : signed) return std_logic_vector is
        variable W_v : std_logic_vector(DiffBits_c - 1 downto 0) := (others => '0');
    begin
        if P_c > 0 then
            W_v(DWs_c - 1 downto 0) := std_logic_vector(dz(DWs_c - 1 downto 0));
            if P_c > 1 then
                W_v(P_c * DWs_c - 1 downto DWs_c) := ctx((P_c - 1) * DWs_c - 1 downto 0);
            end if;
        end if;
        return W_v;
    end function;

    -- Sign sgn+(e) of the double-resolution prediction error (49) from the high-resolution sum h:
    -- with the double-resolution predicted sample s~ and the maximum error m, e > 0 if s~ < 2 (s - m)
    -- (quantizer index q > 0), e < 0 if s~ >= 2 (s + m + 1) (q < 0), else e = 0 for even and e = -1
    -- for odd s~ (q = 0, s' = s^) (41), (48)
    function errorSign (h : signed; i : Item_r) return std_logic is
        variable Hw_v : signed(HW_c - 1 downto 0);
        variable Vs_v : signed(VW_c - 1 downto 0);
    begin
        Hw_v := resize(h, HW_c);
        Vs_v := resize(Hw_v(R_c - 1 downto Om_c + 1), VW_c);
        if i.AAlways = '1' or (i.ANever = '0' and Vs_v < i.T1) then
            return '1';
        elsif i.BAlways = '1' or (i.BNever = '0' and Vs_v >= i.T2) then
            return '0';
        elsif Vs_v <= TLo_c then
            return '1';
        elsif Vs_v >= THi_c then
            return '0';
        end if;
        return Vs_v(0);
    end function;

begin

    -----------------------------------------------------------------------------------------------
    -- Assertions
    -----------------------------------------------------------------------------------------------
    assert XSize_g > 1 or (not Full_c and (Sum_c = SumWideColumn_c or Sum_c = SumNarrowColumn_c))
        report "ocp_predictor: images of width 1 need reduced prediction and column-oriented local sums (CCSDS 4.3.1, 4.4.1)"
        severity failure;
    assert RegisterSize_g >= maximum(32, D_c + Om_c + 2)
        report "ocp_predictor: RegisterSize_g must be at least max(32, D + Omega + 2) (CCSDS 4.7.2)"
        severity failure;
    assert WeightUpdateVmin_g <= WeightUpdateVmax_g
        report "ocp_predictor: WeightUpdateVmin_g must not exceed WeightUpdateVmax_g (CCSDS 4.10.2)"
        severity failure;
    assert not (PeriodicUpdate_g and Bsq_c and not Lossless_c)
        report "ocp_predictor: periodic error limit updating is not allowed with BSQ order (CCSDS 4.8.2.4.4)"
        severity failure;
    assert not (RuntimeConfig_g and PeriodicUpdate_g and not Lossless_c)
        report "ocp_predictor: RuntimeConfig_g excludes periodic error limit updating (CCSDS 4.8.2.4)"
        severity failure;
    assert not (RuntimeConfig_g and ((UseAbs_c and AbsBandDependent_g) or (UseRel_c and RelBandDependent_g)))
        report "ocp_predictor: RuntimeConfig_g excludes band-dependent error limits (CCSDS 4.8.2.3)"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Combinational process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v          : TwoProcess_r;
        variable O_v        : Item_r;
        variable Zi_v       : natural;
        variable Xi_v       : natural;
        variable Yi_v       : natural;
        variable XLast_v    : boolean;
        variable YLast_v    : boolean;
        variable ZLast_v    : boolean;
        variable SubEnd_v   : boolean;
        variable SrcVld_v   : std_logic;
        variable SrcData_v  : std_logic_vector(D_c - 1 downto 0);
        variable SrcEnd_v   : std_logic;
        variable FromIn_v   : boolean;
        variable XMid_v     : boolean;
        variable Block_v    : boolean;
        variable Issue_v    : boolean;
        variable First_v    : boolean;
        variable Init_v     : boolean;
        variable NeedW_v    : boolean;
        variable RunRows_v  : boolean;
        variable RunRowsP_v : boolean;
        variable Lsame_v    : natural;
        variable Lcross_v   : natural;
        variable Advance_v  : boolean;
        variable Zn_v       : natural;
        variable Dt_v       : integer;
        variable Xs_v       : integer;
        variable StartS_v   : std_logic;
        variable NA_v       : natural range 0 to 65536;
        variable NR_v       : natural range 0 to 65536;
        variable Sig_v      : signed(SW_c + 2 downto 0);
        variable Ctx_v      : std_logic_vector(DiffBits_c - 1 downto 0);
        variable Mod_v      : signed(HW_c - 1 downto 0);
        variable Hw_v       : signed(HW_c - 1 downto 0);
        variable RelM_v     : unsigned(SW_c + 16 downto 0);
        variable M_v        : unsigned(15 downto 0);
        variable L1_v       : signed(VW_c - 1 downto 0);
        variable L2_v       : signed(VW_c - 1 downto 0);
        variable Tm_v       : signed(TW_c downto 0);
        variable Rho_v      : integer range -64 to 63;
        variable Act_v      : boolean;
        variable Wload_v    : WeightArr_t;
        variable Wb_v       : WeightSet_t;
        variable SelI_v     : natural range 0 to NC_c - 1;
        variable SgnC_v     : std_logic;
        variable Rem_v      : unsigned(18 downto 0);
        variable QAbs_v     : unsigned(QW_c - 1 downto 0);
        variable QAbsS_v    : signed(QW_c downto 0);
        variable SPrime_v   : signed(SW_c + 1 downto 0);
        variable Corr_v     : signed(RW_c - 1 downto 0);
        variable Th1_v      : unsigned(QW_c - 1 downto 0);
        variable Th2_v      : unsigned(QW_c - 1 downto 0);
        variable Par_v      : signed(QW_c downto 0);
        variable SRep2_v    : signed(RW_c - 1 downto 0);

        -- Pipeline registers of the stages: inputs (r) and outputs (v)
        alias Inp1_i      : Item_r is r.P(0);
        alias Out1_o      : Item_r is v.P(1);
        alias InpRam_i    : Item_r is r.P(StRam_c - 1);
        alias OutRam_o    : Item_r is v.P(StRam_c);
        alias InpDiff_i   : Item_r is r.P(StDiff_c - 1);
        alias OutDiff_o   : Item_r is v.P(StDiff_c);
        alias InpInc_i    : Item_r is r.P(StInc_c - 1);
        alias OutInc_o    : Item_r is v.P(StInc_c);
        alias InpProd_i   : Item_r is r.P(StProd_c - 1);
        alias OutProd_o   : Item_r is v.P(StProd_c);
        alias InpSgn_i    : Item_r is r.P(StSgn_c - 1);
        alias OutSgn_o    : Item_r is v.P(StSgn_c);
        alias InpPredB_i  : Item_r is r.P(StPredB_c - 1);
        alias OutPredB_o  : Item_r is v.P(StPredB_c);
        alias InpQuant_i  : Item_r is r.P(StQuant_c - 1);
        alias OutQuant_o  : Item_r is v.P(StQuant_c);
        alias InpLimit_i  : Item_r is r.P(StLimit_c - 1);
        alias OutLimit_o  : Item_r is v.P(StLimit_c);
        alias InpRep_i    : Item_r is r.P(StRep_c - 1);
        alias OutRep_o    : Item_r is v.P(StRep_c);
        alias InpRepMul_i : Item_r is r.P(StRepMul_c - 1);
        alias OutRepMul_o : Item_r is v.P(StRepMul_c);
        alias InpRepSum_i : Item_r is r.P(StRepSum_c - 1);
        alias OutRepSum_o : Item_r is v.P(StRepSum_c);
        alias InpUpd_i    : Item_r is r.P(StUpd_c - 1);
        alias WbRep_i     : Item_r is r.P(StRepSum_c);
        alias WbRam_i     : Item_r is r.P(StRam_c);
        alias WbDz_i      : Item_r is r.P(StDz_c);
        alias WbUpd_i     : Item_r is r.P(StUpd_c);
        alias WbOut_i     : Item_r is r.P(StOut_c);

        variable Use_v : std_logic_vector(11 downto 0);
    begin
        v := r;

        -- Defaults of the handshake signals and of the memory write ports
        In_Ready  <= '0';
        Lim_Ready <= '0';
        SrWrEna   <= '0';
        SrWrAddr  <= (others => '0');
        SrWrData  <= (others => '0');
        RepWrEna  <= '0';
        RowWrEna  <= '0';
        RepWrAddr <= (others => '0');
        RepWrData <= (others => '0');
        LimWrAddr <= (others => '0');
        AbsWrEna  <= '0';
        RelWrEna  <= '0';
        InWrEna   <= '0';
        OutWrEna  <= '0';
        OutWrAddr <= (others => '0');
        OutWrData <= (others => '0');
        StartS_v  := '0';
        -- Memory errors of reads whose data the pipeline uses: the memories are also read in cycles
        -- without an item, so the flags count when an item takes the data (the stage of the item, the
        -- weights unless initial, the handshakes of the output FIFO and of the stride output buffer)
        Use_v     := (others => toSl(InpRam_i.Valid = '1' and InpRam_i.Kind = ItemSample_c));
        Use_v(5)  := toSl(InpProd_i.Valid = '1' and InpProd_i.Kind = ItemSample_c and InpProd_i.Init = '0');
        Use_v(8)  := FifoOutVld and FifoOutRdy;
        Use_v(10) := r.ORd(2);
        v.EccSec  := or(EccSecVec and Use_v);
        v.EccDed  := or(EccDedVec and Use_v);

        Zi_v := to_integer(r.Z);
        Xi_v := to_integer(r.X);
        Yi_v := to_integer(r.Y);
        -- Last position of every dimension and of the sub-frame: the generics, or the dimensions of the
        -- image (runtime configuration)
        if RuntimeConfig_g then
            XLast_v  := r.X = r.CurXMax;
            YLast_v  := r.Y = r.CurYMax;
            ZLast_v  := r.Z = r.CurZMax;
            SubEnd_v := r.Z = r.SubLow + r.CurMm1;
        else
            XLast_v  := Xi_v = XSize_g - 1;
            YLast_v  := Yi_v = YSize_g - 1;
            ZLast_v  := Zi_v = ZSize_g - 1;
            SubEnd_v := r.Z = r.SubLow + M_c - 1;
        end if;
        SeqStart <= '0';

        -- Number of error limit values per update (CCSDS 5.4.2.2.2)
        NA_v := 0;
        NR_v := 0;
        if UseAbs_c then
            NA_v := 1;
            if AbsBandDependent_g then
                NA_v := ZSize_g;
            end if;
        end if;
        if UseRel_c then
            NR_v := 1;
            if RelBandDependent_g then
                NR_v := ZSize_g;
            end if;
        end if;

        -- Pipeline: every item moves on by one stage
        for k in 1 to NSt_c - 1 loop
            v.P(k) := r.P(k - 1);
        end loop;

        -------------------------------------------------------------------------------------------
        -- Stage 0: issue of the next item in the input order
        -------------------------------------------------------------------------------------------
        O_v       := r.P(0);
        O_v.Valid := '0';
        Issue_v   := false;

        -- Room in the output FIFO for every item in flight
        Block_v := r.Inflight + to_integer(unsigned(FifoLevel)) + 2 > FifoDepth_c;

        if Periodic_c and r.LimDone = '0' and r.X = 0 and r.Z = 0 and r.SubLow = 0 and
           (r.Y mod 2 ** UpdatePeriodExp_g) = 0 then
            -- Periodic error limit updating (CCSDS 4.8.2.4): the values enter the output sequence
            if not Block_v then
                Lim_Ready <= '1';
                if Lim_Valid = '1' then
                    O_v.Valid  := '1';
                    O_v.Last   := '0';
                    O_v.LimVal := unsigned(Lim_Data);
                    if r.LimIdx < NA_v then
                        O_v.Kind  := ItemAbsLimit_c;
                        LimWrAddr <= std_logic_vector(to_unsigned(r.LimIdx, LimWrAddr'length));
                        if AbsBandDependent_g then
                            AbsWrEna <= '1';
                        else
                            v.AbsConst := unsigned(Lim_Data);
                        end if;
                    else
                        O_v.Kind  := ItemRelLimit_c;
                        LimWrAddr <= std_logic_vector(to_unsigned(r.LimIdx - NA_v, LimWrAddr'length));
                        if RelBandDependent_g then
                            RelWrEna <= '1';
                        else
                            v.RelConst := unsigned(Lim_Data);
                        end if;
                    end if;
                    if r.LimIdx = NA_v + NR_v - 1 then
                        v.LimDone := '1';
                        v.LimIdx  := 0;
                    else
                        v.LimIdx := r.LimIdx + 1;
                    end if;
                end if;
            end if;
        elsif not Stride_c then
            -- Source of the sample: the input. With the runtime configuration the first sample of an image
            -- is accepted together with the configuration into the hold register, and issued from there
            -- once the image-start sequencer has computed the issue conditions of the image (CO-RC-03,
            -- CO-RC-05)
            SrcVld_v  := In_Valid;
            SrcData_v := In_Data;
            SrcEnd_v  := In_End;
            FromIn_v  := true;
            if RuntimeConfig_g then
                if r.Hold = '1' then
                    SrcVld_v  := not r.SeqBusy;
                    SrcData_v := r.HoldData;
                    SrcEnd_v  := r.HoldEnd;
                    FromIn_v  := false;
                elsif r.ImgFresh = '1' then
                    SrcVld_v := '0';
                    FromIn_v := false;
                    In_Ready <= Cfg_Ready;
                    if In_Valid = '1' and Cfg_Ready = '1' then
                        SeqStart   <= '1';
                        v.Hold     := '1';
                        v.HoldData := In_Data;
                        v.HoldEnd  := In_End;
                        v.SeqBusy  := '1';
                        v.CurNx    := resize(unsigned(Cfg_XSize), XW_c);
                        v.CurXMax  := resize(unsigned(Cfg_XSize) - 1, XW_c);
                        v.CurYMax  := resize(unsigned(Cfg_YSize) - 1, YW_c);
                        v.CurZMax  := resize(unsigned(Cfg_ZSize) - 1, ZW_c);
                        v.AbsConst := unsigned(Cfg_AbsLimit);
                        v.RelConst := unsigned(Cfg_RelLimit);
                        if RuntimeParams_g then
                            v.CurTInc := to_integer(unsigned(Cfg_WeightInterval));
                            v.CurVmin := to_integer(signed(Cfg_WeightVmin));
                            v.CurVmax := to_integer(signed(Cfg_WeightVmax));
                        end if;
                    end if;
                end if;
            end if;

            First_v := r.RowBase = 0 and r.X = 0;
            Init_v  := r.RowBase + resize(r.X, TW_c) = 1;
            -- The weights come from the memory unless the sample needs none (t = 0), starts with the
            -- initial weights (t = 1) or continues a speculative run of its band
            RunRows_v := RunRows_c or (RuntimeConfig_g and r.RunRows = '1');
            NeedW_v   := Cmax_c > 0 and not First_v and not Init_v and (not Spec_c or (not RunRows_v and r.X = 0));
            if RuntimeConfig_g then
                Lsame_v  := r.LFix;
                Lcross_v := r.LCross;
            else
                Lsame_v  := Lfix_c;
                Lcross_v := Lcross_c;
            end if;
            if NeedW_v then
                Lsame_v := maximum(Lsame_v, Lw_c);
            end if;

            -- Samples the next one depends on must have left the feedback loops
            for i in 1 to SbLen_c loop
                if r.Sb(i).Valid = '1' then
                    if i < Lsame_v and r.Sb(i).Band = r.Z then
                        Block_v := true;
                    end if;
                    if i < Lcross_v and r.Z > 0 and r.Sb(i).Band = r.Z - 1 then
                        if r.Sb(i).X = r.X or (Narrow_c and r.Y = 0 and r.X > 0 and r.Sb(i).X = r.X - 1) then
                            Block_v := true;
                        end if;
                    end if;
                end if;
            end loop;

            if not Block_v then
                if FromIn_v then
                    In_Ready <= '1';
                end if;
                if SrcVld_v = '1' then
                    Issue_v      := true;
                    O_v.Valid    := '1';
                    O_v.Kind     := ItemSample_c;
                    O_v.X        := r.X;
                    O_v.Y        := r.Y;
                    O_v.Z        := r.Z;
                    O_v.T        := r.RowBase + resize(r.X, TW_c);
                    O_v.First    := toSl(First_v);
                    O_v.Init     := toSl(Init_v);
                    O_v.Sample   := toSample(SrcData_v);
                    O_v.SubFirst := toSl(r.Z = r.SubLow);
                    O_v.SubLast  := toSl(SubEnd_v or ZLast_v);
                    O_v.AbsLim   := r.AbsConst;
                    O_v.RelLim   := r.RelConst;
                    O_v.Nx       := r.CurNx;
                    O_v.XLast    := toSl(XLast_v);
                    O_v.RunRows  := toSl(RunRows_v);
                    O_v.TInc     := r.CurTInc;
                    O_v.Vmin     := r.CurVmin;
                    O_v.Vmax     := r.CurVmax;
                    if Bsq_c then
                        O_v.Last := toSl(ZLast_v and YLast_v and XLast_v);
                    else
                        O_v.Last := toSl(YLast_v and XLast_v and ZLast_v);
                    end if;
                    if not FromIn_v then
                        v.Hold := '0';
                    end if;
                    -- Sample of the previous band at t = 0 (CCSDS 4.7.3)
                    if First_v then
                        O_v.Alt  := r.LastT0;
                        v.LastT0 := toSample(SrcData_v);
                    end if;

                    -- Lossless compression without damping: the sample representatives are the
                    -- samples (4.9.2)
                    if RepIsSample_c then
                        SrWrEna   <= '1';
                        SrWrAddr  <= srAddr(r.Z, r.Y = 0, Xi_v);
                        SrWrData  <= SrcData_v;
                        RepWrEna  <= '1';
                        RowWrEna  <= toSl(r.X = 0);
                        RepWrAddr <= bandAddr(r.Z);
                        RepWrData <= SrcData_v;
                    end if;

                    -- Next position in the input order (5.4.2)
                    if Bsq_c then
                        if XLast_v then
                            v.X := (others => '0');
                            if YLast_v then
                                v.Y       := (others => '0');
                                v.RowBase := (others => '0');
                                if ZLast_v then
                                    v.Z := (others => '0');
                                else
                                    v.Z := r.Z + 1;
                                end if;
                            else
                                v.Y := r.Y + 1;
                                if RuntimeConfig_g then
                                    v.RowBase := r.RowBase + r.CurNx;
                                else
                                    v.RowBase := r.RowBase + XSize_g;
                                end if;
                            end if;
                        else
                            v.X := r.X + 1;
                        end if;
                    else
                        if SubEnd_v or ZLast_v then
                            v.Z := r.SubLow;
                            if XLast_v then
                                v.X := (others => '0');
                                if ZLast_v then
                                    v.Z       := (others => '0');
                                    v.SubLow  := (others => '0');
                                    v.LimDone := '0';
                                    if YLast_v then
                                        v.Y       := (others => '0');
                                        v.RowBase := (others => '0');
                                    else
                                        v.Y := r.Y + 1;
                                        if RuntimeConfig_g then
                                            v.RowBase := r.RowBase + r.CurNx;
                                        else
                                            v.RowBase := r.RowBase + XSize_g;
                                        end if;
                                    end if;
                                elsif RuntimeConfig_g then
                                    v.SubLow := r.SubLow + r.CurM;
                                    v.Z      := r.SubLow + r.CurM;
                                else
                                    v.SubLow := r.SubLow + M_c;
                                    v.Z      := r.SubLow + M_c;
                                end if;
                            else
                                v.X := r.X + 1;
                            end if;
                        else
                            v.Z := r.Z + 1;
                        end if;
                    end if;

                    -- Early end of the image (CO-FR-03): this sample is the last item, the next sample
                    -- is the first sample of a new image
                    if SrcEnd_v = '1' then
                        O_v.Last  := '1';
                        v.X       := (others => '0');
                        v.Y       := (others => '0');
                        v.Z       := (others => '0');
                        v.SubLow  := (others => '0');
                        v.RowBase := (others => '0');
                        v.LimDone := '0';
                    end if;
                end if;
            end if;
        else
            -- Stride order: input into the input buffer while it has room for the samples not yet
            -- processed (all of them have an input index of at least LowA)
            Block_v  := false;
            StartS_v := '0';
            if r.ArrIn < NArr_c and r.ArrIn - r.LowA < InDepth_c and r.EndV = '0' then
                In_Ready <= '1';
                if In_Valid = '1' then
                    InWrEna  <= '1';
                    v.ArrIn  := r.ArrIn + 1;
                    StartS_v := toSl(r.ArrIn = 0);
                    -- Early end: the image ends with this sample (PR-FR-02)
                    if In_End = '1' then
                        v.EndV := '1';
                        v.EndA := r.ArrIn;
                    end if;
                end if;
            end if;

            if r.PDone = '0' then
                -- Slot t M + z S: empty outside the image, else the sample once it has arrived, the
                -- samples it depends on have left the feedback loops and the output buffer has room
                -- (after an early end also the slots of the samples after the end sample)
                Advance_v := r.ST < 0 or r.ST >= signed(resize(NPix_c, r.ST'length)) or
                             (r.EndV = '1' and r.SA > signed(resize(r.EndA, r.SA'length)));
                if not Advance_v then
                    First_v := r.ST = 0;
                    Init_v  := r.ST = 1;
                    NeedW_v := Cmax_c > 0 and not First_v and not Init_v;
                    Lsame_v := Lfix_c;
                    if NeedW_v then
                        Lsame_v := maximum(Lsame_v, Lw_c);
                    end if;

                    for i in 1 to SbLen_c loop
                        if r.Sb(i).Valid = '1' then
                            if i < Lsame_v and r.Sb(i).Band = r.SZ then
                                Block_v := true;
                            end if;
                            if i < Lcross_c and r.SZ > 0 and r.Sb(i).Band = r.SZ - 1 then
                                if r.Sb(i).X = r.SX or (Narrow_c and r.SY = 0 and r.SX > 0 and r.Sb(i).X = r.SX - 1) then
                                    Block_v := true;
                                end if;
                            end if;
                        end if;
                    end loop;

                    if unsigned(r.SA) >= resize(r.ArrIn, r.SA'length) or
                       r.SSlot - resize(r.OA, SlW_c) >= OutDepth_c - NSt_c - 8 then
                        Block_v := true;
                    end if;

                    if not Block_v then
                        Issue_v      := true;
                        Advance_v    := true;
                        O_v.Valid    := '1';
                        O_v.Kind     := ItemSample_c;
                        O_v.X        := r.SX;
                        O_v.Y        := resize(unsigned(r.SY), YW_c);
                        O_v.Z        := r.SZ;
                        O_v.T        := resize(unsigned(r.ST), TW_c);
                        O_v.First    := toSl(First_v);
                        O_v.Init     := toSl(Init_v);
                        O_v.SubFirst := toSl(r.SZ = 0);
                        O_v.SubLast  := toSl(r.SZ = M_c - 1);
                        O_v.Last     := toSl(r.SZ = M_c - 1 and r.ST = signed(resize(NPix_c, r.ST'length)) - 1);
                        O_v.AbsLim   := r.AbsConst;
                        O_v.RelLim   := r.RelConst;
                        O_v.ArrIdx   := resize(unsigned(r.SA), AW_c);
                        O_v.SlotIdx  := r.SSlot;
                        if r.SZ = M_c - 1 then
                            v.LowA := r.LowA + M_c;
                        end if;
                        v.IssCnt := r.IssCnt + 1;
                        if O_v.Last = '1' or (r.EndV = '1' and r.IssCnt = r.EndA) then
                            v.PDone := '1';
                        end if;
                    end if;
                end if;

                -- Next slot: band z + Sinv, pixel index t - SJ or t + S - SJ (band wrap)
                if Advance_v and v.PDone = '0' then
                    Zn_v := to_integer(r.SZ) + Sinv_c;
                    if Zn_v >= M_c then
                        Zn_v := Zn_v - M_c;
                        Dt_v := DtWrap_c;
                        v.SA := r.SA + DaWrap_c;
                    else
                        Dt_v := DtNoWrap_c;
                        v.SA := r.SA + DaNoWrap_c;
                    end if;
                    v.SZ := to_unsigned(Zn_v, ZW_c);
                    v.ST := r.ST + Dt_v;
                    Xs_v := to_integer(r.SX) + Dt_v;

                    for k in KMin_c to KMax_c loop
                        if Xs_v >= k * XSize_g and Xs_v < (k + 1) * XSize_g then
                            v.SX := to_unsigned(Xs_v - k * XSize_g, XW_c);
                            v.SY := r.SY + k;
                        end if;
                    end loop;

                    v.SSlot := r.SSlot + 1;
                end if;
            elsif (r.OA = NArr_c or (r.EndV = '1' and r.OA = r.EndA + 1)) and r.ORd = "00" then
                -- Image processed and output: the next image starts with slot 0
                v.ArrIn  := (others => '0');
                v.LowA   := (others => '0');
                v.SZ     := (others => '0');
                v.ST     := (others => '0');
                v.SX     := (others => '0');
                v.SY     := (others => '0');
                v.SA     := (others => '0');
                v.SSlot  := (others => '0');
                v.PDone  := '0';
                v.OA     := (others => '0');
                v.OZ     := (others => '0');
                v.OSlot  := (others => '0');
                v.DoneOk := '0';
                v.EndV   := '0';
                v.IssCnt := (others => '0');
            end if;
        end if;
        v.P(0) := O_v;

        -- Image-start sequencer done: the issue conditions of the image apply to its first sample, which
        -- leaves the hold register in the next clock cycle
        if RuntimeConfig_g and SeqDone = '1' then
            v.SeqBusy := '0';
            v.CurM    := resize(unsigned(SeqM), ZW_c);
            v.CurMm1  := resize(unsigned(SeqM) - 1, ZW_c);
            v.LFix    := to_integer(unsigned(SeqLFix));
            v.LCross  := to_integer(unsigned(SeqLCross));
            v.RunRows := SeqRunRows;
        end if;

        -- Start of an image: the first item after the last sample of the previous image
        Img_Start <= '0';
        if Stride_c then
            Img_Start <= StartS_v;
        elsif O_v.Valid = '1' then
            Img_Start  <= r.ImgFresh;
            v.ImgFresh := O_v.Last and toSl(O_v.Kind = ItemSample_c);
        end if;

        -- Scoreboard of the issued samples
        for i in SbLen_c downto 2 loop
            v.Sb(i) := r.Sb(i - 1);
        end loop;

        v.Sb(1).Valid := toSl(Issue_v);
        v.Sb(1).Band  := O_v.Z;
        v.Sb(1).X     := O_v.X;

        -------------------------------------------------------------------------------------------
        -- Stage 1: band parameters, weight update scaling exponent (CCSDS 4.10.2)
        -------------------------------------------------------------------------------------------
        Zi_v := to_integer(Inp1_i.Z);

        for j in 0 to C1_c - 1 loop
            Out1_o.Zeta(j) := signed(ZetaRom_c(Zi_v)((j + 1) * 4 - 1 downto j * 4));
        end loop;

        Out1_o.Phi := 0;
        Out1_o.Psi := 0;
        if Theta_c > 0 then
            Out1_o.Phi := PhiRom_c(Zi_v);
            Out1_o.Psi := PsiRom_c(Zi_v);
        end if;
        -- Error limit values: from the generics, from the periodic updates or from the configuration of the
        -- image (both taken at the issue stage)
        if not Periodic_c and not RuntimeConfig_g then
            Out1_o.AbsLim := to_unsigned(AbsRom_c(Zi_v), 16);
            Out1_o.RelLim := to_unsigned(RelRom_c(Zi_v), 16);
        end if;

        -- (50): rho(t) = clip(vmin + floor((t - Nx) / t_inc), vmin, vmax), plus D - Omega
        if RuntimeConfig_g then
            Tm_v := signed('0' & Inp1_i.T) - signed('0' & resize(Inp1_i.Nx, TW_c));
        else
            Tm_v := signed('0' & Inp1_i.T) - XSize_g;
        end if;
        if RuntimeParams_g then
            -- The parameters of the image of the item (PR-RP-02)
            Tm_v := shift_right(Tm_v, Inp1_i.TInc);
            if Tm_v < 0 then
                Rho_v := Inp1_i.Vmin;
            elsif Tm_v > Inp1_i.Vmax - Inp1_i.Vmin then
                Rho_v := Inp1_i.Vmax;
            else
                Rho_v := Inp1_i.Vmin + to_integer(Tm_v);
            end if;
        else
            Tm_v := shift_right(Tm_v, WeightUpdateInterval_g);
            if Tm_v < 0 then
                Rho_v := WeightUpdateVmin_g;
            elsif Tm_v > WeightUpdateVmax_g - WeightUpdateVmin_g then
                Rho_v := WeightUpdateVmax_g;
            else
                Rho_v := WeightUpdateVmin_g + to_integer(Tm_v);
            end if;
        end if;
        Out1_o.Rho := Rho_v + D_c - Om_c;

        -------------------------------------------------------------------------------------------
        -- Stage 2 (StRam_c): neighbors and error limits from the memories; local sum (4.4)
        -------------------------------------------------------------------------------------------

        -- Previous line: NE from the line memory, N and NW from the window of the band (forwarded
        -- from the previous sample of the band if it was the last sample at this stage); N of the
        -- first column is the first sample representative of the previous line
        OutRam_o.NE := toSample(SrRdData);
        if r.WinValid = '1' and r.WinBand = InpRam_i.Z then
            OutRam_o.NW := r.WinN;
            OutRam_o.N  := r.WinNE;
        else
            OutRam_o.NW := toSample(WinRdData(2 * D_c - 1 downto D_c));
            OutRam_o.N  := toSample(WinRdData(D_c - 1 downto 0));
        end if;
        if InpRam_i.X = 0 then
            OutRam_o.N := toSample(RowRdData);
        end if;
        OutRam_o.W := toSample(RepRdData);
        -- Narrow local sums in row 0: sample representative of the previous band (4.4)
        if InpRam_i.First = '0' then
            OutRam_o.Alt := toSample(SrRdData);
        end if;
        if InpRam_i.Valid = '1' and InpRam_i.Kind = ItemSample_c then
            v.WinValid := '1';
            v.WinBand  := InpRam_i.Z;
            v.WinN     := OutRam_o.N;
            v.WinNE    := OutRam_o.NE;
        end if;

        if Periodic_c then
            if AbsBandDependent_g then
                OutRam_o.AbsLim := unsigned(AbsRdData);
            end if;
            if RelBandDependent_g then
                OutRam_o.RelLim := unsigned(RelRdData);
            end if;
        end if;
        OutRam_o.Ctx := DiffRdData;
        if Stride_c then
            OutRam_o.Ctx    := CtxRdData;
            OutRam_o.Sample := toSample(InRdData);
            if InpRam_i.First = '1' then
                OutRam_o.Alt := r.LastT0;
                if InpRam_i.Valid = '1' and InpRam_i.Kind = ItemSample_c then
                    v.LastT0 := toSample(InRdData);
                end if;
            end if;
        end if;

        Sig_v := (others => '0');
        if RuntimeConfig_g then
            XMid_v := InpRam_i.X > 0 and InpRam_i.XLast = '0';
        else
            XMid_v := InpRam_i.X > 0 and InpRam_i.X /= XSize_g - 1;
        end if;

        case Sum_c is
            when SumWideNeighbor_c =>
                if InpRam_i.Y > 0 and XMid_v then
                    Sig_v := resize(OutRam_o.W, Sig_v'length) + OutRam_o.NW + OutRam_o.N + OutRam_o.NE;
                elsif InpRam_i.Y = 0 then
                    Sig_v := shift_left(resize(OutRam_o.W, Sig_v'length), 2);
                elsif InpRam_i.X = 0 then
                    Sig_v := shift_left(resize(OutRam_o.N, Sig_v'length) + OutRam_o.NE, 1);
                else
                    Sig_v := resize(OutRam_o.W, Sig_v'length) + OutRam_o.NW + shift_left(resize(OutRam_o.N, Sig_v'length), 1);
                end if;
            when SumNarrowNeighbor_c =>
                if InpRam_i.Y > 0 and XMid_v then
                    Sig_v := resize(OutRam_o.NW, Sig_v'length) + shift_left(resize(OutRam_o.N, Sig_v'length), 1) + OutRam_o.NE;
                elsif InpRam_i.Y = 0 then
                    if InpRam_i.Z > 0 then
                        Sig_v := shift_left(resize(OutRam_o.Alt, Sig_v'length), 2);
                    else
                        Sig_v := shift_left(resize(SMid_c, Sig_v'length), 2);
                    end if;
                elsif InpRam_i.X = 0 then
                    Sig_v := shift_left(resize(OutRam_o.N, Sig_v'length) + OutRam_o.NE, 1);
                else
                    Sig_v := shift_left(resize(OutRam_o.NW, Sig_v'length) + OutRam_o.N, 1);
                end if;
            when SumWideColumn_c =>
                if InpRam_i.Y > 0 then
                    Sig_v := shift_left(resize(OutRam_o.N, Sig_v'length), 2);
                else
                    Sig_v := shift_left(resize(OutRam_o.W, Sig_v'length), 2);
                end if;
            when others =>
                if InpRam_i.Y > 0 then
                    Sig_v := shift_left(resize(OutRam_o.N, Sig_v'length), 2);
                elsif InpRam_i.Z > 0 then
                    Sig_v := shift_left(resize(OutRam_o.Alt, Sig_v'length), 2);
                else
                    Sig_v := shift_left(resize(SMid_c, Sig_v'length), 2);
                end if;
        end case;

        OutRam_o.Sigma := Sig_v;

        -------------------------------------------------------------------------------------------
        -- Stage 3 (StDiff_c): local difference vector (4.5)
        -------------------------------------------------------------------------------------------

        -- Central local differences of the previous bands: from the memory for the first band of a
        -- sub-frame (BI) or of a pixel (BSQ), from the previous sample otherwise
        Ctx_v := InpDiff_i.Ctx;
        if Stride_c then
            -- Stride order: the previous band at the pixel left its differences in the context memory
            if InpDiff_i.Z = 0 then
                Ctx_v := (others => '0');
            end if;
        elsif not Bsq_c and InpDiff_i.SubFirst = '0' then
            Ctx_v := r.LastWord;
        elsif not DiffRam_c then
            Ctx_v := (others => '0');
        end if;

        OutDiff_o.U := (others => (others => '0'));
        if Full_c then
            -- Directional local differences (4.5.2)
            if InpDiff_i.Y > 0 then
                OutDiff_o.U(0) := resize(shift_left(resize(InpDiff_i.N, DW_c), 2) - InpDiff_i.Sigma, DW_c);
                if InpDiff_i.X > 0 then
                    OutDiff_o.U(1) := resize(shift_left(resize(InpDiff_i.W, DW_c), 2) - InpDiff_i.Sigma, DW_c);
                    OutDiff_o.U(2) := resize(shift_left(resize(InpDiff_i.NW, DW_c), 2) - InpDiff_i.Sigma, DW_c);
                else
                    OutDiff_o.U(1) := resize(shift_left(resize(InpDiff_i.N, DW_c), 2) - InpDiff_i.Sigma, DW_c);
                    OutDiff_o.U(2) := resize(shift_left(resize(InpDiff_i.N, DW_c), 2) - InpDiff_i.Sigma, DW_c);
                end if;
            end if;
        end if;

        -- Central local differences of the Pz* previous bands (4.5.3)
        for i in 1 to P_c loop
            if i <= to_integer(InpDiff_i.Z) then
                OutDiff_o.U(3 * toInt(Full_c) + i - 1) := resize(signed(Ctx_v(i * DWs_c - 1 downto (i - 1) * DWs_c)), DW_c);
            end if;
        end loop;

        -- Central local difference of the sample (24); zero at t = 0
        OutDiff_o.Dz := (others => '0');
        if InpDiff_i.First = '0' then
            OutDiff_o.Dz := resize(shift_left(resize(InpDiff_i.Sample, DW_c), 2) - InpDiff_i.Sigma, DW_c);
        end if;
        OutDiff_o.Ctx := Ctx_v;
        if RepIsSample_c then
            OutDiff_o.Ctx := shiftCtx(Ctx_v, OutDiff_o.Dz);
            if InpDiff_i.Valid = '1' and InpDiff_i.Kind = ItemSample_c then
                v.LastWord := OutDiff_o.Ctx;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Stage 4 (StInc_c): weight increments for both error signs (4.10.3), thresholds of the error
        -- sign (maximum error m: the absolute error limit, zero in lossless compression)
        -------------------------------------------------------------------------------------------
        Act_v := InpInc_i.Valid = '1' and InpInc_i.Kind = ItemSample_c and InpInc_i.First = '0';

        for j in 0 to C1_c - 1 loop
            OutInc_o.IncP(j) := (others => '0');
            OutInc_o.IncN(j) := (others => '0');
            if Act_v and j < Cmax_c then
                OutInc_o.IncP(j) := weightInc(InpInc_i.U(j), '1', InpInc_i.Rho + to_integer(InpInc_i.Zeta(j)));
                OutInc_o.IncN(j) := weightInc(InpInc_i.U(j), '0', InpInc_i.Rho + to_integer(InpInc_i.Zeta(j)));
            end if;
        end loop;

        M_v := (others => '0');
        if not Lossless_c then
            M_v := InpInc_i.AbsLim;
        end if;
        L1_v             := shift_left(resize(InpInc_i.Sample, VW_c) - signed(resize(M_v, VW_c)), 1);
        L2_v             := shift_left(resize(InpInc_i.Sample, VW_c) + signed(resize(M_v, VW_c)) + 1, 1);
        OutInc_o.T1      := L1_v - C0_c;
        OutInc_o.T2      := L2_v - C0_c;
        OutInc_o.ANever  := toSl(L1_v <= Lo_c);
        OutInc_o.AAlways := toSl(L1_v > Hi_c);
        OutInc_o.BAlways := toSl(L2_v <= Lo_c);
        OutInc_o.BNever  := toSl(L2_v > Hi_c);

        -------------------------------------------------------------------------------------------
        -- Stage 5 (StProd_c): weight vectors of the sample (from the memory, the initial weights or the
        -- speculative loop), products of the predicted central local difference (4.7.1) and the local
        -- sum term of the high-resolution predicted sample (4.7.2)
        -------------------------------------------------------------------------------------------

        if InpProd_i.Init = '1' then

            for j in 0 to C1_c - 1 loop
                Wload_v(j) := signed(WeightRom_c(to_integer(InpProd_i.Z))((j + 1) * WW_c - 1 downto j * WW_c));
            end loop;

        else

            for j in 0 to C1_c - 1 loop
                Wload_v(j) := signed(WRdData((j + 1) * WW_c - 1 downto j * WW_c));
            end loop;

        end if;

        -- The run of the band continues across rows (runtime configuration: in the image of the item)
        RunRowsP_v := RunRows_c or (RuntimeConfig_g and InpProd_i.RunRows = '1');

        for c in 0 to NC_c - 1 loop
            Wb_v(c) := Wload_v;
            -- Continuation of the run of the band; a cycle without a sample (whose other fields are
            -- those of the previous item) passes the candidates on
            if Spec_c and (InpProd_i.Valid = '0' or
                           (InpProd_i.Init = '0' and (RunRowsP_v or InpProd_i.X /= 0 or InpProd_i.First = '1'))) then
                Wb_v(c) := r.CW(c);
            end if;
        end loop;

        OutProd_o.WCand := Wb_v;

        for c in 0 to NC_c - 1 loop

            for j in 0 to C1_c - 1 loop
                if j < Cmax_c then
                    OutProd_o.Part(c)(j) := resize(Wb_v(c)(j) * InpProd_i.U(j), AccW_c);
                else
                    OutProd_o.Part(c)(j) := (others => '0');
                end if;
            end loop;

            OutProd_o.Part(c)(C1_c) := resize(shift_left(resize(InpProd_i.Sigma, AccW_c) - shift_left(resize(SMid_c, AccW_c), 2),
                                                         Om_c), AccW_c);
        end loop;

        -- Adder trees
        for k in 1 to TreeSt_c loop

            for c in 0 to NC_c - 1 loop
                v.P(StProd_c + k).Part(c) := reduce4(r.P(StProd_c + k - 1).Part(c));
            end loop;

        end loop;

        -------------------------------------------------------------------------------------------
        -- Stage StSgn_c: selection of the candidate by the signs of the two previous samples, error
        -- sign (49), high-resolution predicted sample (4.7.2)
        -------------------------------------------------------------------------------------------
        SelI_v := 0;
        if Spec_c then
            SelI_v := (2 * toInt(r.S1 = '1') + toInt(r.S2 = '1')) mod NC_c;
        end if;
        SgnC_v           := errorSign(InpSgn_i.Part(SelI_v)(0), InpSgn_i);
        OutSgn_o.SgnPlus := SgnC_v;
        OutSgn_o.Wgt     := InpSgn_i.WCand(SelI_v);
        Hw_v             := resize(InpSgn_i.Part(SelI_v)(0), HW_c);
        -- mod*R (1.6.1): R-bit two's complement wrap
        Mod_v         := resize(Hw_v(R_c - 1 downto 0), HW_c);
        OutSgn_o.ModV := Mod_v + shift_left(resize(SMid_c, HW_c), Om_c + 2) + shift_left(to_signed(1, HW_c), Om_c + 1);
        if Spec_c then
            v.S1 := SgnC_v;
            v.S2 := r.S1;
        end if;

        -------------------------------------------------------------------------------------------
        -- Speculative weight loop: weight vectors of the next sample for the signs of the sample at
        -- stage StProd_c and of the previous sample; the sign of the sample two before is known now
        -------------------------------------------------------------------------------------------
        if Spec_c then
            Act_v := InpProd_i.Valid = '1' and InpProd_i.Kind = ItemSample_c and InpProd_i.First = '0';

            for b in 0 to 1 loop

                for b1 in 0 to 1 loop

                    for j in 0 to C1_c - 1 loop
                        v.CW((2 * b + b1) mod NC_c)(j) := Wb_v((2 * b1 + toInt(SgnC_v = '1')) mod NC_c)(j);
                        if Act_v and j < Cmax_c then
                            if b = 1 then
                                v.CW((2 * b + b1) mod NC_c)(j) := weightAdd(Wb_v((2 * b1 + toInt(SgnC_v = '1')) mod NC_c)(j),
                                                                            InpProd_i.IncP(j));
                            else
                                v.CW((2 * b + b1) mod NC_c)(j) := weightAdd(Wb_v((2 * b1 + toInt(SgnC_v = '1')) mod NC_c)(j),
                                                                            InpProd_i.IncN(j));
                            end if;
                        end if;
                    end loop;

                end loop;

            end loop;

        end if;

        -------------------------------------------------------------------------------------------
        -- Stage StPredB_c: double-resolution predicted sample (4.7.3)
        -------------------------------------------------------------------------------------------
        if InpPredB_i.First = '1' then
            -- (38): t = 0
            if P_c > 0 and InpPredB_i.Z > 0 then
                OutPredB_o.SDbl := shift_left(resize(InpPredB_i.Alt, SW_c + 1), 1);
            else
                OutPredB_o.SDbl := shift_left(resize(SMid_c, SW_c + 1), 1);
            end if;
            OutPredB_o.STilde := (others => '0');
        else
            Mod_v             := clipSigned(InpPredB_i.ModV, shift_left(resize(SMin_c, HW_c), Om_c + 2),
                                            shift_left(resize(SMax_c, HW_c), Om_c + 2) + shift_left(to_signed(1, HW_c), Om_c + 1));
            OutPredB_o.STilde := resize(Mod_v, STildeW_c);
            OutPredB_o.SDbl   := resize(shift_right(Mod_v, Om_c + 1), SW_c + 1);
        end if;

        -------------------------------------------------------------------------------------------
        -- Stage StQuant_c: predicted sample (4.7.4), prediction residual (4.8.1)
        -------------------------------------------------------------------------------------------
        OutQuant_o.SHat    := resize(shift_right(InpQuant_i.SDbl, 1), SW_c);
        OutQuant_o.Res     := resize(InpQuant_i.Sample, SW_c + 1) - shift_right(InpQuant_i.SDbl, 1);
        OutQuant_o.RelProd := resize(InpQuant_i.RelLim * unsigned(abs(resize(shift_right(InpQuant_i.SDbl, 1), SW_c + 1))), OutQuant_o.RelProd'length);

        -------------------------------------------------------------------------------------------
        -- Stage StLimit_c: maximum error (4.8.2), dividends of the quantizer; with relative error
        -- limits the error sign (49) for the weight update
        -------------------------------------------------------------------------------------------
        M_v    := (others => '0');
        RelM_v := shift_right(InpLimit_i.RelProd, D_c);
        if InpLimit_i.First = '0' then

            case Fid_c is
                when FidAbsolute_c =>
                    M_v := InpLimit_i.AbsLim;
                when FidRelative_c =>
                    M_v := resize(RelM_v, 16);
                when FidBoth_c =>
                    if RelM_v < InpLimit_i.AbsLim then
                        M_v := resize(RelM_v, 16);
                    else
                        M_v := InpLimit_i.AbsLim;
                    end if;
                when others =>
                    M_v := (others => '0');
            end case;

        end if;
        OutLimit_o.M       := M_v;
        OutLimit_o.Divisor := resize(M_v & '1', 18);

        if not ThreshSign_c then
            -- e = 2 s' - s~ is positive for q > 0, negative for q < 0, and for q = 0 (s' = s^) zero if
            -- s~ is even, -1 if it is odd (41), (48), (49)
            if InpLimit_i.Res > signed('0' & M_v) then
                OutLimit_o.SgnPlus := '1';
            elsif InpLimit_i.Res < -signed('0' & M_v) then
                OutLimit_o.SgnPlus := '0';
            else
                OutLimit_o.SgnPlus := not InpLimit_i.SDbl(0);
            end if;
        end if;

        -- Dividends: |residual| + m and the distances of the prediction to the sample limits (56)
        OutLimit_o.Dvd(0) := resize(unsigned(abs(InpLimit_i.Res)), QW_c) + M_v;
        OutLimit_o.Dvd(1) := resize(unsigned(resize(InpLimit_i.SHat, QW_c + 1) - SMin_c), QW_c) + M_v;
        OutLimit_o.Dvd(2) := resize(unsigned(resize(SMax_c, QW_c + 1) - InpLimit_i.SHat), QW_c) + M_v;
        OutLimit_o.Remd   := (others => (others => '0'));
        if Lossless_c then
            OutLimit_o.Quo := OutLimit_o.Dvd;
        else
            OutLimit_o.Quo := (others => (others => '0'));
        end if;

        -------------------------------------------------------------------------------------------
        -- Stage StUpd_c: updated weights (4.10.3)
        -------------------------------------------------------------------------------------------

        for j in 0 to C1_c - 1 loop
            if InpUpd_i.SgnPlus = '1' then
                v.P(StUpd_c).Wgt(j) := weightAdd(InpUpd_i.Wgt(j), InpUpd_i.IncP(j));
            else
                v.P(StUpd_c).Wgt(j) := weightAdd(InpUpd_i.Wgt(j), InpUpd_i.IncN(j));
            end if;
        end loop;

        -------------------------------------------------------------------------------------------
        -- Quantizer (near-lossless): restoring division of the three dividends by 2m + 1, one
        -- quotient bit per stage
        -------------------------------------------------------------------------------------------
        for k in 1 to DivSt_c loop

            for i in 0 to 2 loop
                Rem_v := r.P(StLimit_c + k - 1).Remd(i)(17 downto 0) & r.P(StLimit_c + k - 1).Dvd(i)(QW_c - k);
                if Rem_v >= r.P(StLimit_c + k - 1).Divisor then
                    v.P(StLimit_c + k).Remd(i)          := Rem_v - r.P(StLimit_c + k - 1).Divisor;
                    v.P(StLimit_c + k).Quo(i)(QW_c - k) := '1';
                else
                    v.P(StLimit_c + k).Remd(i) := Rem_v;
                end if;
            end loop;

        end loop;

        -------------------------------------------------------------------------------------------
        -- Stage StRep_c: quantizer index (41), clipped bin center (48)
        -------------------------------------------------------------------------------------------
        QAbs_v := InpRep_i.Quo(0);
        if InpRep_i.First = '1' then
            OutRep_o.Q     := resize(InpRep_i.Res, QW_c + 1);
            OutRep_o.SClip := InpRep_i.Sample;
            OutRep_o.Corr  := (others => '0');
        else
            if InpRep_i.Res < 0 then
                OutRep_o.Q := -signed(resize(QAbs_v, QW_c + 1));
                SPrime_v   := resize(InpRep_i.SHat, SW_c + 2) - signed(resize(InpRep_i.Dvd(0) - resize(InpRep_i.Remd(0), QW_c), SW_c + 2));
            else
                OutRep_o.Q := signed(resize(QAbs_v, QW_c + 1));
                SPrime_v   := resize(InpRep_i.SHat, SW_c + 2) + signed(resize(InpRep_i.Dvd(0) - resize(InpRep_i.Remd(0), QW_c), SW_c + 2));
            end if;
            SPrime_v       := clipSigned(SPrime_v, resize(SMin_c, SW_c + 2), resize(SMax_c, SW_c + 2));
            OutRep_o.SClip := resize(SPrime_v, SW_c);
            -- sgn(q) m psi 2^(Omega - Theta) of (47)
            Corr_v := shift_left(resize(signed('0' & InpRep_i.M) * to_signed(InpRep_i.Psi, 6), RW_c), Om_c - Theta_c);
            if OutRep_o.Q < 0 then
                Corr_v := -Corr_v;
            elsif OutRep_o.Q = 0 then
                Corr_v := (others => '0');
            end if;
            OutRep_o.Corr := Corr_v;
        end if;
        Th1_v := InpRep_i.Quo(1);
        Th2_v := InpRep_i.Quo(2);
        if Th1_v < Th2_v then
            OutRep_o.ThetaM := Th1_v;
        else
            OutRep_o.ThetaM := Th2_v;
        end if;

        -------------------------------------------------------------------------------------------
        -- Stage StRepMul_c: products of the sample representative (47), mapped quantizer index (55)
        -------------------------------------------------------------------------------------------
        OutRepMul_o.Num1 := resize(to_signed(4 * (2 ** Theta_c) - 4 * InpRepMul_i.Phi, 8) *
                                   (shift_left(resize(InpRepMul_i.SClip, RW_c - 8), Om_c) - resize(InpRepMul_i.Corr, RW_c - 8)), RW_c);
        OutRepMul_o.Num2 := resize(to_signed(InpRepMul_i.Phi, 6) * InpRepMul_i.STilde, RW_c) - shift_left(to_signed(InpRepMul_i.Phi, RW_c), Om_c + 1);

        QAbsS_v := abs(InpRepMul_i.Q);
        QAbs_v  := unsigned(QAbsS_v(QW_c - 1 downto 0));
        if InpRepMul_i.SDbl(0) = '1' then
            Par_v := -InpRepMul_i.Q;
        else
            Par_v := InpRepMul_i.Q;
        end if;
        if QAbs_v > InpRepMul_i.ThetaM then
            OutRepMul_o.Delta := resize(QAbs_v + InpRepMul_i.ThetaM, D_c);
        elsif Par_v >= 0 and Par_v <= signed('0' & InpRepMul_i.ThetaM) then
            OutRepMul_o.Delta := resize(shift_left(QAbs_v, 1), D_c);
        else
            OutRepMul_o.Delta := resize(shift_left(QAbs_v, 1) - 1, D_c);
        end if;

        -------------------------------------------------------------------------------------------
        -- Stage StRepSum_c: sample representative (46), (47), central local difference (24)
        -------------------------------------------------------------------------------------------
        if InpRepSum_i.First = '1' then
            OutRepSum_o.SRep := InpRepSum_i.Sample;
        else
            SRep2_v          := shift_right(InpRepSum_i.Num1 + InpRepSum_i.Num2, Om_c + Theta_c + 1);
            OutRepSum_o.SRep := resize(shift_right(SRep2_v + 1, 1), SW_c);
        end if;
        if not RepIsSample_c then
            if InpRepSum_i.First = '0' then
                OutRepSum_o.Dz := resize(shift_left(resize(OutRepSum_o.SRep, DW_c), 2) - InpRepSum_i.Sigma, DW_c);
            end if;
            OutRepSum_o.Ctx := shiftCtx(InpRepSum_i.Ctx, OutRepSum_o.Dz);
            if InpRepSum_i.Valid = '1' and InpRepSum_i.Kind = ItemSample_c then
                v.LastWord := OutRepSum_o.Ctx;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Write back of the band state
        -------------------------------------------------------------------------------------------
        -- Sample representatives of the line, of the previous sample and of the first column (near-
        -- lossless compression or damping)
        if not RepIsSample_c then
            if WbRep_i.Valid = '1' and WbRep_i.Kind = ItemSample_c then
                SrWrEna  <= '1';
                RepWrEna <= '1';
                RowWrEna <= toSl(WbRep_i.X = 0);
            end if;
            SrWrAddr  <= srAddr(WbRep_i.Z, WbRep_i.Y = 0, to_integer(WbRep_i.X));
            SrWrData  <= std_logic_vector(WbRep_i.SRep(D_c - 1 downto 0));
            RepWrAddr <= bandAddr(WbRep_i.Z);
            RepWrData <= std_logic_vector(WbRep_i.SRep(D_c - 1 downto 0));
        end if;

        -- Stride order: central local differences for the next band at the pixel
        CtxWrEna  <= toSl(Stride_c) and WbRep_i.Valid and toSl(WbRep_i.Kind = ItemSample_c);
        CtxWrAddr <= ctxAddr(WbRep_i.Z, WbRep_i.T);
        CtxWrData <= WbRep_i.Ctx;

        -- Window of the previous line: N and NE become NW and N of the next sample of the band
        WinWrEna  <= WbRam_i.Valid and toSl(WbRam_i.Kind = ItemSample_c);
        WinWrAddr <= bandAddr(WbRam_i.Z);
        WinWrData <= std_logic_vector(WbRam_i.N(D_c - 1 downto 0)) & std_logic_vector(WbRam_i.NE(D_c - 1 downto 0));

        -- Central local differences: the last band of a sub-frame (BI) or every band (BSQ)
        DiffWrEna <= toSl(DiffRam_c) and WbDz_i.Valid and toSl(WbDz_i.Kind = ItemSample_c) and
                     (toSl(Bsq_c) or WbDz_i.SubLast);
        if Bsq_c then
            DiffWrAddr <= std_logic_vector(resize(WbDz_i.T, DiffWrAddr'length));
        else
            DiffWrAddr <= std_logic_vector(resize(WbDz_i.X, DiffWrAddr'length));
        end if;
        DiffWrData <= WbDz_i.Ctx;

        -- Updated weights
        WWrEna  <= toSl(WRam_c) and WbUpd_i.Valid and toSl(WbUpd_i.Kind = ItemSample_c) and not WbUpd_i.First;
        WWrAddr <= bandAddr(WbUpd_i.Z);

        for j in 0 to C1_c - 1 loop
            WWrData((j + 1) * WW_c - 1 downto j * WW_c) <= std_logic_vector(WbUpd_i.Wgt(j));
        end loop;

        -------------------------------------------------------------------------------------------
        -- Output FIFO: the items directly, in stride order through the output buffer
        -------------------------------------------------------------------------------------------
        FifoInValid <= WbOut_i.Valid;
        if WbOut_i.Kind = ItemSample_c then
            FifoInData(OutW_c - 1 downto 0)                 <= std_logic_vector(resize(WbOut_i.Delta, OutW_c));
            FifoInData(OutW_c + 1 + ZW_c downto OutW_c + 2) <= std_logic_vector(WbOut_i.Z);
        else
            FifoInData(OutW_c - 1 downto 0)                 <= std_logic_vector(resize(WbOut_i.LimVal, OutW_c));
            FifoInData(OutW_c + 1 + ZW_c downto OutW_c + 2) <= (others => '0');
        end if;
        FifoInData(OutW_c + 1 downto OutW_c) <= WbOut_i.Kind;
        FifoInData(OutW_c + 2 + ZW_c)        <= WbOut_i.First and toSl(WbOut_i.Kind = ItemSample_c);
        FifoInData(OutW_c + 3 + ZW_c)        <= WbOut_i.Init and toSl(WbOut_i.Kind = ItemSample_c);
        FifoInData(OutW_c + 4 + ZW_c)        <= WbOut_i.Last;

        if Stride_c then
            -- Output buffer at the input index of the sample; slot of the last finished sample
            OutWrEna  <= WbOut_i.Valid and toSl(WbOut_i.Kind = ItemSample_c);
            OutWrAddr <= std_logic_vector(resize(WbOut_i.ArrIdx, OutWrAddr'length));
            OutWrData <= std_logic_vector(WbOut_i.Delta);
            if WbOut_i.Valid = '1' and WbOut_i.Kind = ItemSample_c then
                v.DoneSlot := WbOut_i.SlotIdx;
                v.DoneOk   := '1';
            end if;

            -- Read in the input order once the sample is finished (its slot is not later than the slot of
            -- the last finished sample) and the output FIFO has room for the reads in flight
            v.ORd     := '0' & r.ORd(1);
            v.OBand2  := r.OBand1;
            v.OFlags2 := r.OFlags1;
            if r.OA < NArr_c and not (r.EndV = '1' and r.OA > r.EndA) and r.DoneOk = '1' and
               r.OSlot <= r.DoneSlot and
               to_integer(unsigned(FifoLevel)) + 4 <= FifoDepth_c then
                v.ORd(1) := '1';
                v.OBand1 := r.OZ;
                -- First sample (t = 0), first coded sample (t = 1), last sample of the image
                v.OFlags1(0) := toSl(r.OA < M_c);
                v.OFlags1(1) := toSl(r.OA >= M_c and r.OA < 2 * M_c);
                v.OFlags1(2) := toSl(r.OA = NArr_c - 1 or (r.EndV = '1' and r.OA = r.EndA));
                v.OA         := r.OA + 1;
                if r.OZ = M_c - 1 then
                    v.OZ    := (others => '0');
                    v.OSlot := r.OSlot - ((M_c - 1) * S_c - M_c);
                else
                    v.OZ    := r.OZ + 1;
                    v.OSlot := r.OSlot + S_c;
                end if;
            end if;

            FifoInValid                                     <= r.ORd(2);
            FifoInData(OutW_c - 1 downto 0)                 <= std_logic_vector(resize(unsigned(OutRdData), OutW_c));
            FifoInData(OutW_c + 1 downto OutW_c)            <= ItemSample_c;
            FifoInData(OutW_c + 1 + ZW_c downto OutW_c + 2) <= std_logic_vector(r.OBand2);
            FifoInData(OutW_c + 2 + ZW_c)                   <= r.OFlags2(0);
            FifoInData(OutW_c + 3 + ZW_c)                   <= r.OFlags2(1);
            FifoInData(OutW_c + 4 + ZW_c)                   <= r.OFlags2(2);
        end if;

        -- Items in flight: issued and not yet written to the output FIFO
        if v.P(0).Valid = '1' and WbOut_i.Valid = '0' then
            v.Inflight := r.Inflight + 1;
        elsif v.P(0).Valid = '0' and WbOut_i.Valid = '1' then
            v.Inflight := r.Inflight - 1;
        end if;

        r_next <= v;
    end process;

    -- Read addresses of the memories: position of the item at the issue stage; weights of the item
    -- at stage 2, read for stage 5
    p_rdaddr : process (all) is
        variable Xi_v   : natural;
        variable Y_v    : unsigned(YW_c - 1 downto 0);
        variable Z_v    : unsigned(ZW_c - 1 downto 0);
        variable XEnd_v : boolean;
    begin
        -- Position of the next sample: in stride order the current slot
        if Stride_c then
            Xi_v := to_integer(r.SX);
            Y_v  := resize(unsigned(r.SY), YW_c);
            Z_v  := r.SZ;
        else
            Xi_v := to_integer(r.X);
            Y_v  := r.Y;
            Z_v  := r.Z;
        end if;
        -- NE of the previous line; in row 0 the previous band at x - 1 (narrow local sums)
        if RuntimeConfig_g then
            XEnd_v := r.X = r.CurXMax;
        else
            XEnd_v := Xi_v >= XSize_g - 1;
        end if;
        if Y_v > 0 then
            if not XEnd_v then
                SrRdAddr <= srAddr(Z_v, Y_v = 1, Xi_v + 1);
            else
                SrRdAddr <= srAddr(Z_v, Y_v = 1, Xi_v);
            end if;
        elsif Z_v > 0 and Xi_v > 0 then
            SrRdAddr <= srAddr(Z_v - 1, true, Xi_v - 1);
        else
            SrRdAddr <= srAddr(Z_v, true, 0);
        end if;
        BandRdAddr <= bandAddr(Z_v);
        if Z_v > 0 then
            CtxRdAddr <= ctxAddr(Z_v - 1, unsigned(r.ST(TW_c - 1 downto 0)));
        else
            CtxRdAddr <= ctxAddr(Z_v, unsigned(r.ST(TW_c - 1 downto 0)));
        end if;
        InRdAddr  <= std_logic_vector(resize(unsigned(r.SA), InRdAddr'length));
        InWrAddr  <= std_logic_vector(resize(r.ArrIn, InWrAddr'length));
        OutRdAddr <= std_logic_vector(resize(r.OA, OutRdAddr'length));
        WRdAddr   <= bandAddr(r.P(2).Z);
        if Bsq_c then
            DiffRdAddr <= std_logic_vector(resize(r.RowBase + resize(r.X, TW_c), DiffRdAddr'length));
        else
            DiffRdAddr <= std_logic_vector(resize(r.X, DiffRdAddr'length));
        end if;
        LimRdAddr <= std_logic_vector(resize(r.Z, LimRdAddr'length));
    end process;

    -- Outputs
    Out_Data  <= OutData(OutW_c - 1 downto 0);
    Out_Kind  <= OutData(OutW_c + 1 downto OutW_c);
    Out_Band  <= OutData(OutW_c + 1 + ZW_c downto OutW_c + 2);
    Out_First <= OutData(OutW_c + 2 + ZW_c);
    Out_Init  <= OutData(OutW_c + 3 + ZW_c);
    Out_Last  <= OutData(OutW_c + 4 + ZW_c);
    Ecc_Sec   <= r.EccSec;
    Ecc_Ded   <= r.EccDed;

    -----------------------------------------------------------------------------------------------
    -- Sequential process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then

                for k in 0 to NSt_c - 1 loop
                    r.P(k).Valid <= '0';
                end loop;

                for i in 1 to SbLen_c loop
                    r.Sb(i).Valid <= '0';
                end loop;

                r.X        <= (others => '0');
                r.Y        <= (others => '0');
                r.Z        <= (others => '0');
                r.SubLow   <= (others => '0');
                r.RowBase  <= (others => '0');
                r.LimDone  <= '0';
                r.LimIdx   <= 0;
                r.ImgFresh <= '1';
                r.ArrIn    <= (others => '0');
                r.LowA     <= (others => '0');
                r.SZ       <= (others => '0');
                r.ST       <= (others => '0');
                r.SX       <= (others => '0');
                r.SY       <= (others => '0');
                r.SA       <= (others => '0');
                r.SSlot    <= (others => '0');
                r.PDone    <= '0';
                r.OA       <= (others => '0');
                r.OZ       <= (others => '0');
                r.OSlot    <= (others => '0');
                r.DoneOk   <= '0';
                r.ORd      <= "00";
                r.EndV     <= '0';
                r.IssCnt   <= (others => '0');
                r.WinValid <= '0';
                r.Inflight <= 0;
                r.EccSec   <= '0';
                r.EccDed   <= '0';
                r.AbsConst <= (others => '0');
                r.RelConst <= (others => '0');
                if RuntimeConfig_g then
                    r.Hold    <= '0';
                    r.SeqBusy <= '0';
                    r.CurNx   <= to_unsigned(XSize_g, XW_c);
                    r.CurXMax <= to_unsigned(XSize_g - 1, XW_c);
                    r.CurYMax <= to_unsigned(YSize_g - 1, YW_c);
                    r.CurZMax <= to_unsigned(ZSize_g - 1, ZW_c);
                    r.CurM    <= to_unsigned(M_c, ZW_c);
                    r.CurMm1  <= to_unsigned(M_c - 1, ZW_c);
                    r.LFix    <= LfixMax_c;
                    r.LCross  <= LcrossMax_c;
                    r.RunRows <= toSl(RunRows_c);
                end if;
                if RuntimeParams_g then
                    r.CurTInc <= WeightUpdateInterval_g;
                    r.CurVmin <= WeightUpdateVmin_g;
                    r.CurVmax <= WeightUpdateVmax_g;
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Image-start sequencer (runtime configuration)
    -----------------------------------------------------------------------------------------------
    Cfg_Take <= SeqStart;

    g_start : if RuntimeConfig_g generate

        i_start : entity work.ocp_image_start
            generic map (
                Bsq_g           => Bsq_c,
                SubFrameDepth_g => SubFrameDepth_g,
                RuntimeM_g      => RuntimeParams_g,
                PredBands_g     => P_c,
                RepIsSample_g   => RepIsSample_c,
                WUsed_g         => WUsed_c,
                CrossRep_g      => CrossRep_c,
                LWin_g          => LwinMem_c,
                LRep_g          => Lrep_c,
                LDw_g           => Ldw_c
            )
            port map (
                Clk         => Clk,
                Rst         => Rst,
                Start       => SeqStart,
                In_XSize    => Cfg_XSize,
                In_YSize    => Cfg_YSize,
                In_ZSize    => Cfg_ZSize,
                In_M        => Cfg_M,
                Done        => SeqDone,
                Out_M       => SeqM,
                Out_Gap1    => open,
                Out_RunRows => SeqRunRows,
                Out_LFix    => SeqLFix,
                Out_LCross  => SeqLCross
            );

    else generate
        SeqDone    <= '0';
        SeqM       <= (others => '0');
        SeqRunRows <= '0';
        SeqLFix    <= (others => '0');
        SeqLCross  <= (others => '0');
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Memories
    -----------------------------------------------------------------------------------------------
    -- Error injection: the memory of the selected channel
    g_inj : for i in 0 to 11 generate
        InjVec(i) <= ErrInj_Valid when to_integer(unsigned(ErrInj_Channel)) = i else '0';
    end generate;

    i_sr_ram : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g       => SrDepth_c,
            Width_g       => D_c,
            RamStyle_g    => RamStyle_g,
            EccPipeline_g => 1
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => SrWrAddr,
            Wr_Ena         => SrWrEna,
            Wr_Data        => SrWrData,
            Rd_Addr        => SrRdAddr,
            Rd_Data        => SrRdData,
            Rd_Valid       => open,
            Rd_EccSec      => EccSecVec(0),
            Rd_EccDed      => EccDedVec(0),
            ErrInj_BitFlip => injPattern(eccCodewordWidth(D_c), ErrInj_Double),
            ErrInj_Valid   => InjVec(0)
        );

    -- The window is always forwarded when consecutive samples belong to the same band
    g_win : if not Gap1_c generate

        i_win_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => BandSlots_c,
                Width_g       => 2 * D_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => WinWrAddr,
                Wr_Ena         => WinWrEna,
                Wr_Data        => WinWrData,
                Rd_Addr        => BandRdAddr,
                Rd_Data        => WinRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(1),
                Rd_EccDed      => EccDedVec(1),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(2 * D_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(1)
            );

    else generate
        WinRdData    <= (others => '0');
        EccSecVec(1) <= '0';
        EccDedVec(1) <= '0';
    end generate;

    i_rep_ram : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g       => BandSlots_c,
            Width_g       => D_c,
            RamStyle_g    => RamStyle_g,
            EccPipeline_g => 1
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => RepWrAddr,
            Wr_Ena         => RepWrEna,
            Wr_Data        => RepWrData,
            Rd_Addr        => BandRdAddr,
            Rd_Data        => RepRdData,
            Rd_Valid       => open,
            Rd_EccSec      => EccSecVec(2),
            Rd_EccDed      => EccDedVec(2),
            ErrInj_BitFlip => injPattern(eccCodewordWidth(D_c), ErrInj_Double),
            ErrInj_Valid   => InjVec(2)
        );

    i_row_ram : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g       => BandSlots_c,
            Width_g       => D_c,
            RamStyle_g    => RamStyle_g,
            EccPipeline_g => 1
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => RepWrAddr,
            Wr_Ena         => RowWrEna,
            Wr_Data        => RepWrData,
            Rd_Addr        => BandRdAddr,
            Rd_Data        => RowRdData,
            Rd_Valid       => open,
            Rd_EccSec      => EccSecVec(3),
            Rd_EccDed      => EccDedVec(3),
            ErrInj_BitFlip => injPattern(eccCodewordWidth(D_c), ErrInj_Double),
            ErrInj_Valid   => InjVec(3)
        );

    g_diff : if DiffRam_c generate

        i_diff_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => DiffDepth_c,
                Width_g       => DiffBits_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => DiffWrAddr,
                Wr_Ena         => DiffWrEna,
                Wr_Data        => DiffWrData,
                Rd_Addr        => DiffRdAddr,
                Rd_Data        => DiffRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(4),
                Rd_EccDed      => EccDedVec(4),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(DiffBits_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(4)
            );

    else generate
        DiffRdData   <= (others => '0');
        EccSecVec(4) <= '0';
        EccDedVec(4) <= '0';
    end generate;

    g_weights : if WRam_c generate

        i_weight_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => BandSlots_c,
                Width_g       => WBits_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => WWrAddr,
                Wr_Ena         => WWrEna,
                Wr_Data        => WWrData,
                Rd_Addr        => WRdAddr,
                Rd_Data        => WRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(5),
                Rd_EccDed      => EccDedVec(5),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(WBits_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(5)
            );

    else generate
        WRdData      <= (others => '0');
        EccSecVec(5) <= '0';
        EccDedVec(5) <= '0';
    end generate;

    g_abs : if Periodic_c and UseAbs_c and AbsBandDependent_g generate

        i_abs_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => ZSize_g + 1,
                Width_g       => 16,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => LimWrAddr,
                Wr_Ena         => AbsWrEna,
                Wr_Data        => Lim_Data,
                Rd_Addr        => LimRdAddr,
                Rd_Data        => AbsRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(6),
                Rd_EccDed      => EccDedVec(6),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(16), ErrInj_Double),
                ErrInj_Valid   => InjVec(6)
            );

    else generate
        AbsRdData    <= (others => '0');
        EccSecVec(6) <= '0';
        EccDedVec(6) <= '0';
    end generate;

    g_rel : if Periodic_c and UseRel_c and RelBandDependent_g generate

        i_rel_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => ZSize_g + 1,
                Width_g       => 16,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => LimWrAddr,
                Wr_Ena         => RelWrEna,
                Wr_Data        => Lim_Data,
                Rd_Addr        => LimRdAddr,
                Rd_Data        => RelRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(7),
                Rd_EccDed      => EccDedVec(7),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(16), ErrInj_Double),
                ErrInj_Valid   => InjVec(7)
            );

    else generate
        RelRdData    <= (others => '0');
        EccSecVec(7) <= '0';
        EccDedVec(7) <= '0';
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Stride order: input buffer, output buffer, central local differences of every band
    -----------------------------------------------------------------------------------------------
    g_stride : if Stride_c generate

        i_in_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => InDepth_c,
                Width_g       => D_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => InWrAddr,
                Wr_Ena         => InWrEna,
                Wr_Data        => In_Data,
                Rd_Addr        => InRdAddr,
                Rd_Data        => InRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(9),
                Rd_EccDed      => EccDedVec(9),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(D_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(9)
            );

        i_out_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => OutDepth_c,
                Width_g       => D_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => OutWrAddr,
                Wr_Ena         => OutWrEna,
                Wr_Data        => OutWrData,
                Rd_Addr        => OutRdAddr,
                Rd_Data        => OutRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(10),
                Rd_EccDed      => EccDedVec(10),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(D_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(10)
            );

        i_ctx_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g       => CtxDepth_c,
                Width_g       => DiffBits_c,
                RamStyle_g    => RamStyle_g,
                EccPipeline_g => 1
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                Wr_Addr        => CtxWrAddr,
                Wr_Ena         => CtxWrEna,
                Wr_Data        => CtxWrData,
                Rd_Addr        => CtxRdAddr,
                Rd_Data        => CtxRdData,
                Rd_Valid       => open,
                Rd_EccSec      => EccSecVec(11),
                Rd_EccDed      => EccDedVec(11),
                ErrInj_BitFlip => injPattern(eccCodewordWidth(DiffBits_c), ErrInj_Double),
                ErrInj_Valid   => InjVec(11)
            );

    else generate
        InRdData               <= (others => '0');
        OutRdData              <= (others => '0');
        CtxRdData              <= (others => '0');
        EccSecVec(11 downto 9) <= (others => '0');
        EccDedVec(11 downto 9) <= (others => '0');
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Output FIFO
    -----------------------------------------------------------------------------------------------
    i_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g    => FifoW_c,
            Depth_g    => FifoDepth_c,
            RamStyle_g => RamStyle_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => FifoInData,
            In_Valid          => FifoInValid,
            In_Ready          => open,
            In_Level          => FifoLevel,
            Out_Data          => FifoOutData,
            Out_Valid         => FifoOutVld,
            Out_Ready         => FifoOutRdy,
            Out_EccSec        => EccSecVec(8),
            Out_EccDed        => EccDedVec(8),
            In_ErrInj_BitFlip => injPattern(eccCodewordWidth(FifoW_c), ErrInj_Double),
            In_ErrInj_Valid   => InjVec(8)
        );

    -- Registered output: the SECDED correction of the FIFO and the first stage of the entropy coder
    -- are in different cycles
    i_out_stage : entity olo.olo_base_pl_stage
        generic map (
            Width_g => FifoW_c
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => FifoOutVld,
            In_Ready  => FifoOutRdy,
            In_Data   => FifoOutData,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready,
            Out_Data  => OutData
        );

end architecture;
