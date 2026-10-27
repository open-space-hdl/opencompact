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
    use olo.olo_base_pkg_attribute.all;

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
        -- Runtime configuration: NX, NY, NZ (1 to the maxima XSize_g, YSize_g, ZSize_g) and the
        -- band-independent error limit values of every image from the configuration inputs
        RuntimeConfig_g        : boolean                   := false;
        -- Runtime parameters (with RuntimeConfig_g only): user-defined data, M, the weight update parameters
        -- and the entropy coder parameters of every image from the configuration inputs
        RuntimeParams_g        : boolean                   := false;
        -- Implementation: width of the compressed image interface in bits (8, 16, 32 or 64), speculative
        -- weight loop of the predictor, memory style
        OutWidth_g             : positive                  := 8;
        Speculation_g          : boolean                   := true;
        RamStyle_g             : string                    := "auto"
    );
    port (
        Clk                : in    std_logic;
        Rst                : in    std_logic;
        -- Image samples in the input order (unsigned or two's complement); In_Last on the last sample
        -- of every image, In_Error with In_Last: the image ends with an error (UseInLast_g, both ignored
        -- otherwise)
        In_Valid           : in    std_logic;
        In_Ready           : out   std_logic;
        In_Data            : in    std_logic_vector(DynamicRange_g - 1 downto 0);
        In_Last            : in    std_logic                     := '0';
        In_Error           : in    std_logic                     := '0';
        -- Error limit values for periodic error limit updating
        Lim_Valid          : in    std_logic                     := '0';
        Lim_Ready          : out   std_logic;
        Lim_Data           : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Compressed image: byte n of a word in Out_Data(8n + 7 downto 8n), the first byte in bits 7:0;
        -- the last word of an image marks its valid bytes, contiguous from byte 0; Out_Error on the
        -- last word of an image with a framing error ('0' on every other word)
        Out_Valid          : out   std_logic;
        Out_Ready          : in    std_logic;
        Out_Data           : out   std_logic_vector(OutWidth_g - 1 downto 0);
        Out_Keep           : out   std_logic_vector(OutWidth_g / 8 - 1 downto 0);
        Out_Last           : out   std_logic;
        Out_Error          : out   std_logic;
        -- Memory errors (pulses): corrected single error, detected double error
        Ecc_Sec            : out   std_logic;
        Ecc_Ded            : out   std_logic;
        -- Framing error of an image (pulse): In_Last before or missing on the last sample, or In_Error
        Ev_ImageError      : out   std_logic;
        -- Error injection into the next write of memory ErrInj_Channel (user guide, memories): a single
        -- (corrected) or a double (detected) bit error
        ErrInj_Channel     : in    std_logic_vector(3 downto 0)  := (others => '0');
        ErrInj_Double      : in    std_logic                     := '0';
        ErrInj_Valid       : in    std_logic                     := '0';
        -- Runtime configuration (RuntimeConfig_g): NX, NY, NZ and the error limit values of the next
        -- image, taken when its first sample is accepted (Cfg_Taken, a pulse in that clock cycle); the
        -- values taken for the last image, after the range limitation (CO-RC-07)
        Cfg_XSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_YSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_ZSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_AbsLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        Cfg_RelLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Runtime parameters (RuntimeParams_g), taken with the configuration: user-defined data, M (BI
        -- order), log2 t_inc, vmin and vmax (two's complement), Umax, gamma0, gamma*, K, r
        Cfg_UserData       : in    std_logic_vector(7 downto 0)  := (others => '0');
        Cfg_M              : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_WeightInterval : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_WeightVmin     : in    std_logic_vector(4 downto 0)  := (others => '0');
        Cfg_WeightVmax     : in    std_logic_vector(4 downto 0)  := (others => '0');
        Cfg_UnaryLimit     : in    std_logic_vector(5 downto 0)  := (others => '0');
        Cfg_InitCountExp   : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_RescaleSize    : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_AccuInit       : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_RefInterval    : in    std_logic_vector(12 downto 0) := (others => '0');
        Cfg_Taken          : out   std_logic;
        Act_XSize          : out   std_logic_vector(16 downto 0);
        Act_YSize          : out   std_logic_vector(16 downto 0);
        Act_ZSize          : out   std_logic_vector(16 downto 0);
        Act_AbsLimit       : out   std_logic_vector(15 downto 0);
        Act_RelLimit       : out   std_logic_vector(15 downto 0);
        -- Runtime parameters taken for the last image, after the range limitation (CO-RP-02); zero for a
        -- parameter not in use
        Act_UserData       : out   std_logic_vector(7 downto 0);
        Act_M              : out   std_logic_vector(16 downto 0);
        Act_WeightInterval : out   std_logic_vector(3 downto 0);
        Act_WeightVmin     : out   std_logic_vector(4 downto 0);
        Act_WeightVmax     : out   std_logic_vector(4 downto 0);
        Act_UnaryLimit     : out   std_logic_vector(5 downto 0);
        Act_InitCountExp   : out   std_logic_vector(3 downto 0);
        Act_RescaleSize    : out   std_logic_vector(3 downto 0);
        Act_AccuInit       : out   std_logic_vector(3 downto 0);
        Act_RefInterval    : out   std_logic_vector(12 downto 0)
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
    constant Fid_c       : natural  := fidelityCode(Fidelity_g);
    constant UseAbs_c    : boolean  := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
    constant UseRel_c    : boolean  := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
    -- Images of width 1 need reduced prediction and column-oriented local sums (CCSDS 4.3.1, 4.4.1)
    constant Wide_c      : boolean := fullPrediction(PredictionMode_g) or
                                       localSumCode(LocalSum_g) = SumWideNeighbor_c or
                                       localSumCode(LocalSum_g) = SumNarrowNeighbor_c;

    -- Runtime configuration: configuration of an image (NX, NY, NZ, absolute and relative error limit value)
    type Cfg_r is record
        X    : unsigned(16 downto 0);
        Y    : unsigned(16 downto 0);
        Z    : unsigned(16 downto 0);
        AbsL : unsigned(15 downto 0);
        RelL : unsigned(15 downto 0);
    end record;

    -- After a reset: the maxima and the first error limit values of the generics (zero for a method not in use)
    function cfgReset return Cfg_r is
        variable C_v : Cfg_r;
    begin
        C_v.X    := to_unsigned(XSize_g, 17);
        C_v.Y    := to_unsigned(YSize_g, 17);
        C_v.Z    := to_unsigned(ZSize_g, 17);
        C_v.AbsL := (others => '0');
        C_v.RelL := (others => '0');
        if UseAbs_c then
            C_v.AbsL := to_unsigned(vecElem(AbsErrorLimits_g, 0), 16);
        end if;
        if UseRel_c then
            C_v.RelL := to_unsigned(vecElem(RelErrorLimits_g, 0), 16);
        end if;
        return C_v;
    end function;

    -- Configurations of the images taken at the input and not yet used by the header generator (and the
    -- hybrid coder); registers, like the error flags of the image framer
    constant QDepth_c : positive := 16;

    type CfgQueue_t is array (0 to QDepth_c - 1) of Cfg_r;

    -- Runtime parameters in use (CO-RP-01): M in BI order; Umax, gamma0 and gamma* with the sample-adaptive and
    -- the hybrid coder; K with the sample-adaptive coder and an accumulator initialisation constant; r with the
    -- block-adaptive coder
    constant UseM_c   : boolean := encodingOrderCode(EncodingOrder_g) = OrderBi_c;
    constant UseAdp_c : boolean := Coder_c /= CoderBlock_c;
    constant UseK_c   : boolean := Coder_c = CoderSample_c and not AccuInitBandVarying_g;
    constant UseR_c   : boolean := Coder_c = CoderBlock_c;

    -- Lower bound of gamma0 (CO-RP-02): with the hybrid coder every initial accumulator below 2^(D + gamma0)
    constant G0Min_c : positive := choose(Coder_c = CoderHybrid_c,
                                          hybridG0Min(DynamicRange_g, ZSize_g, HybridAccuInit_g, HybridAccuInitHigh_g),
                                          1);

    -- Values of the parameters of an image (the ranges are those of the decoded header fields)
    type Par_r is record
        User  : natural range 0 to 255;
        M     : natural range 1 to 65536;
        TInc  : natural range 4 to 19;
        Vmin  : integer range -6 to 9;
        Vmax  : integer range -6 to 9;
        Umax  : natural range 1 to 32;
        G0    : natural range 1 to 8;
        GStar : natural range 4 to 11;
        K     : natural range 0 to 15;
        R     : natural range 1 to 4096;
    end record;

    -- The parameters in the encoding of their header fields (architecture, section 6.3)
    type ParCode_r is record
        User  : std_logic_vector(7 downto 0);
        M     : std_logic_vector(15 downto 0);
        TInc  : std_logic_vector(3 downto 0);
        Vmin  : std_logic_vector(3 downto 0);
        Vmax  : std_logic_vector(3 downto 0);
        Umax  : std_logic_vector(4 downto 0);
        GStar : std_logic_vector(2 downto 0);
        G0    : std_logic_vector(2 downto 0);
        K     : std_logic_vector(3 downto 0);
        R     : std_logic_vector(11 downto 0);
    end record;

    -- After a reset: the values of the generics
    function parReset return Par_r is
        variable P_v : Par_r;
    begin
        P_v.User  := UserData_g;
        P_v.M     := minimum(SubFrameDepth_g, ZSize_g);
        P_v.TInc  := WeightUpdateInterval_g;
        P_v.Vmin  := WeightUpdateVmin_g;
        P_v.Vmax  := WeightUpdateVmax_g;
        P_v.Umax  := UnaryLimit_g;
        P_v.G0    := InitialCountExp_g;
        P_v.GStar := RescaleCounterSize_g;
        P_v.K     := 0;
        if UseK_c then
            P_v.K := vecElem(AccuInit_g, 0);
        end if;
        P_v.R := RefInterval_g;
        return P_v;
    end function;

    function encode (p : Par_r) return ParCode_r is
        variable C_v : ParCode_r;
    begin
        C_v.User  := encOffset(p.User, 0, 8);
        C_v.M     := encModPow2(p.M, 16);
        C_v.TInc  := encOffset(p.TInc, 4, 4);
        C_v.Vmin  := encOffset(p.Vmin, -6, 4);
        C_v.Vmax  := encOffset(p.Vmax, -6, 4);
        C_v.Umax  := encModPow2(p.Umax, 5);
        C_v.GStar := encOffset(p.GStar, 4, 3);
        C_v.G0    := encModPow2(p.G0, 3);
        C_v.K     := encOffset(p.K, 0, 4);
        C_v.R     := encModPow2(p.R, 12);
        return C_v;
    end function;

    function decode (c : ParCode_r) return Par_r is
        variable P_v : Par_r;
    begin
        P_v.User  := decOffset(c.User, 0);
        P_v.M     := decModPow2(c.M);
        P_v.TInc  := decOffset(c.TInc, 4);
        P_v.Vmin  := decOffset(c.Vmin, -6);
        P_v.Vmax  := decOffset(c.Vmax, -6);
        P_v.Umax  := decModPow2(c.Umax);
        P_v.GStar := decOffset(c.GStar, 4);
        P_v.G0    := decModPow2(c.G0);
        P_v.K     := decOffset(c.K, 0);
        P_v.R     := decModPow2(c.R);
        return P_v;
    end function;

    -- Queue entry: the fields of the parameters in use (specification, table 2), at these offsets
    constant OfsTInc_c : natural  := 8;
    constant OfsVmin_c : natural  := 12;
    constant OfsVmax_c : natural  := 16;
    constant OfsM_c    : natural  := 20;
    constant OfsUmax_c : natural  := OfsM_c + 16 * toInt(UseM_c);
    constant OfsGSt_c  : natural  := OfsUmax_c + 5;
    constant OfsG0_c   : natural  := OfsGSt_c + 3;
    constant OfsK_c    : natural  := OfsUmax_c + 11 * toInt(UseAdp_c);
    constant OfsR_c    : natural  := OfsK_c + 4 * toInt(UseK_c);
    constant ParW_c    : positive := OfsR_c + 12 * toInt(UseR_c);
    -- Width that holds every field at its offset, also the fields not in use
    constant ParMaxW_c : positive := 64;

    subtype ParEntry_t is std_logic_vector(ParW_c - 1 downto 0);

    function pack (c : ParCode_r) return ParEntry_t is
        variable E_v : std_logic_vector(ParMaxW_c - 1 downto 0) := (others => '0');
    begin
        E_v(7 downto 0)                     := c.User;
        E_v(OfsTInc_c + 3 downto OfsTInc_c) := c.TInc;
        E_v(OfsVmin_c + 3 downto OfsVmin_c) := c.Vmin;
        E_v(OfsVmax_c + 3 downto OfsVmax_c) := c.Vmax;
        if UseM_c then
            E_v(OfsM_c + 15 downto OfsM_c) := c.M;
        end if;
        if UseAdp_c then
            E_v(OfsUmax_c + 4 downto OfsUmax_c) := c.Umax;
            E_v(OfsGSt_c + 2 downto OfsGSt_c)   := c.GStar;
            E_v(OfsG0_c + 2 downto OfsG0_c)     := c.G0;
        end if;
        if UseK_c then
            E_v(OfsK_c + 3 downto OfsK_c) := c.K;
        end if;
        if UseR_c then
            E_v(OfsR_c + 11 downto OfsR_c) := c.R;
        end if;
        return E_v(ParW_c - 1 downto 0);
    end function;

    -- The fields of the parameters not in use are zero
    function unpack (e : ParEntry_t) return ParCode_r is
        variable E_v : std_logic_vector(ParMaxW_c - 1 downto 0) := (others => '0');
        variable C_v : ParCode_r;
    begin
        E_v(ParW_c - 1 downto 0) := e;
        C_v                      := (User => E_v(7 downto 0),
                                     M => (others => '0'),
                                     TInc => E_v(OfsTInc_c + 3 downto OfsTInc_c),
                                     Vmin => E_v(OfsVmin_c + 3 downto OfsVmin_c),
                                     Vmax => E_v(OfsVmax_c + 3 downto OfsVmax_c),
                                     Umax => (others => '0'),
                                     GStar => (others => '0'),
                                     G0 => (others => '0'),
                                     K => (others => '0'),
                                     R => (others => '0'));
        if UseM_c then
            C_v.M := E_v(OfsM_c + 15 downto OfsM_c);
        end if;
        if UseAdp_c then
            C_v.Umax  := E_v(OfsUmax_c + 4 downto OfsUmax_c);
            C_v.GStar := E_v(OfsGSt_c + 2 downto OfsGSt_c);
            C_v.G0    := E_v(OfsG0_c + 2 downto OfsG0_c);
        end if;
        if UseK_c then
            C_v.K := E_v(OfsK_c + 3 downto OfsK_c);
        end if;
        if UseR_c then
            C_v.R := E_v(OfsR_c + 11 downto OfsR_c);
        end if;
        return C_v;
    end function;

    type ParQueue_t is array (0 to QDepth_c - 1) of ParEntry_t;

    -- Decoding the encoding gives back every value of every parameter range (CO-RP-05)
    constant ParamCodingOk_c : boolean := paramCodingExact;

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
    signal SmpEnd   : std_logic;

    -- Image sequencing: header first, then the body
    signal InBody    : std_logic;
    signal StartPend : std_logic;
    signal ImgStart  : std_logic;
    signal Waiting   : natural range 0 to 15 + toInt(RuntimeConfig_g);
    signal PredSec   : std_logic;
    signal PredDed   : std_logic;
    signal CoderSec  : std_logic;
    signal CoderDed  : std_logic;
    signal InjStats  : std_logic;
    signal InjBuffer : std_logic;

    -- Runtime configuration: inputs after the range limitation, configuration taken (first sample of an
    -- image accepted), active configuration, queue (write pointer, read pointers of the header generator and
    -- of the hybrid coder), room in the queue, end of the tail of the hybrid coder
    signal Lim      : Cfg_r;
    signal Take     : std_logic;
    signal Act      : Cfg_r;
    signal Queue    : CfgQueue_t;
    signal QWr      : unsigned(4 downto 0);
    signal QRdH     : unsigned(4 downto 0);
    signal QRdC     : unsigned(4 downto 0);
    signal HeadH    : Cfg_r;
    signal HeadC    : Cfg_r;
    signal CfgReady : std_logic;
    signal HybDone  : std_logic;

    attribute ram_style of Queue    : signal is "registers";
    attribute ramstyle of Queue     : signal is "logic";
    attribute syn_ramstyle of Queue : signal is "registers";

    -- Runtime parameters: inputs after the range limitation, active parameters (encoded), queue of the encoded
    -- parameters and the read pointer of the sample-adaptive and the block-adaptive coder, the entries at the
    -- read pointers (header generator: the encoding; coders: the values), the active values
    signal LimPar : Par_r;
    signal ParAct : ParEntry_t;
    signal PQueue : ParQueue_t;
    signal QRdE   : unsigned(4 downto 0);
    signal HeadPH : ParCode_r;
    signal HeadPC : Par_r;
    signal HeadPE : Par_r;
    signal ActPar : Par_r;

    attribute ram_style of PQueue    : signal is "registers";
    attribute ramstyle of PQueue     : signal is "logic";
    attribute syn_ramstyle of PQueue : signal is "registers";

    -- Runtime parameters on the ports of the predictor (the limited values of the next image), of the sample-adaptive
    -- and the block-adaptive coder (the entry at their read pointer) and of the hybrid coder (the entry of its image)
    signal PredM      : std_logic_vector(16 downto 0);
    signal PredTInc   : std_logic_vector(3 downto 0);
    signal PredVmin   : std_logic_vector(4 downto 0);
    signal PredVmax   : std_logic_vector(4 downto 0);
    signal CoderUmax  : std_logic_vector(5 downto 0);
    signal CoderG0    : std_logic_vector(3 downto 0);
    signal CoderGStar : std_logic_vector(3 downto 0);
    signal CoderK     : std_logic_vector(3 downto 0);
    signal CoderR     : std_logic_vector(12 downto 0);
    signal HybUmax    : std_logic_vector(5 downto 0);
    signal HybG0      : std_logic_vector(3 downto 0);
    signal HybGStar   : std_logic_vector(3 downto 0);

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

    -- Runtime configuration (CO-CF-04): configurations whose header or quantizer cannot follow dimensions and error
    -- limit values that change from image to image stop the elaboration
    assert not (RuntimeConfig_g and PeriodicUpdate_g and Fid_c /= FidLossless_c)
        report "ocp_core: RuntimeConfig_g excludes periodic error limit updating (CO-CF-04)"
        severity failure;

    assert not (RuntimeConfig_g and ((UseAbs_c and AbsBandDependent_g) or (UseRel_c and RelBandDependent_g)))
        report "ocp_core: RuntimeConfig_g excludes band-dependent error limits (CO-CF-04)"
        severity failure;

    assert not (RuntimeConfig_g and ((CustomWeights_g and WeightInitTable_g) or
                                     (WeightExpOffsetsUsed_g and WeightExpOffsetTable_g) or
                                     (SampleRepResolution_g > 0 and DampingBandVarying_g and DampingTable_g) or
                                     (SampleRepResolution_g > 0 and OffsetBandVarying_g and OffsetTable_g) or
                                     (Coder_c = CoderSample_c and AccuInitBandVarying_g and AccuInitTable_g)))
        report "ocp_core: RuntimeConfig_g excludes header tables whose length depends on NZ (CO-CF-04)"
        severity failure;

    assert not (RuntimeConfig_g and SupTableCount_g > 0)
        report "ocp_core: RuntimeConfig_g excludes supplementary information tables (CO-CF-04)"
        severity failure;

    -- Runtime parameters (CO-CF-05, CO-RP-05)
    assert RuntimeConfig_g or not RuntimeParams_g
        report "ocp_core: RuntimeParams_g requires RuntimeConfig_g (CO-CF-05)"
        severity failure;

    assert ParamCodingOk_c
        report "ocp_core: decoding the header field encoding of a runtime parameter does not give its value back " &
               "(CO-RP-05)"
        severity failure;

    assert not RuntimeParams_g or Coder_c /= CoderHybrid_c or G0Min_c <= minimum(8, RescaleCounterSize_g - 1)
        report "ocp_core: with RuntimeParams_g no gamma0 up to min(8, RescaleCounterSize_g - 1) keeps every " &
               "initial accumulator of HybridAccuInit_g below 2^(D + gamma0) (CCSDS 5.4.3.3.4.3, CO-RP-02)"
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
            -- The image ends with the last codeword; the bit packer appends the fill bits before it takes
            -- the header of the next image
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

    -- Bit packer input: header bytes, then the codewords of the entropy coder
    Pk_Valid  <= Cw_Valid when InBody = '1' else Hdr_Valid;
    Pk_Data   <= Cw_Data when InBody = '1' else
                 std_logic_vector(resize(unsigned(Hdr_Data), CwWidth_c));
    Pk_Length <= Cw_Length when InBody = '1' else
                 Hdr_Length;
    Pk_Last   <= Cw_Last when InBody = '1' else '0';
    Cw_Ready  <= Pk_Ready when InBody = '1' else '0';
    Hdr_Ready <= Pk_Ready when InBody = '0' else '0';
    PkEnd     <= Pk_Valid and Pk_Ready and Pk_Last;

    -----------------------------------------------------------------------------------------------
    -- Runtime configuration
    -----------------------------------------------------------------------------------------------
    g_runtime : if RuntimeConfig_g generate

        -- Range limitation (CO-RC-07): an input outside its range is taken as the nearest valid value, so that no
        -- unit addresses outside its memories or counts an image without a bounded end
        p_limit : process (all) is
            variable V_v : Cfg_r;
        begin
            V_v.X := unsigned(Cfg_XSize);
            if V_v.X = 0 then
                V_v.X := to_unsigned(1, 17);
            elsif V_v.X > XSize_g then
                V_v.X := to_unsigned(XSize_g, 17);
            end if;
            if Wide_c and V_v.X = 1 then
                V_v.X := to_unsigned(2, 17);
            end if;
            V_v.Y := unsigned(Cfg_YSize);
            if V_v.Y = 0 then
                V_v.Y := to_unsigned(1, 17);
            elsif V_v.Y > YSize_g then
                V_v.Y := to_unsigned(YSize_g, 17);
            end if;
            V_v.Z := unsigned(Cfg_ZSize);
            if V_v.Z = 0 then
                V_v.Z := to_unsigned(1, 17);
            elsif V_v.Z > ZSize_g then
                V_v.Z := to_unsigned(ZSize_g, 17);
            end if;
            V_v.AbsL := (others => '0');
            if UseAbs_c then
                V_v.AbsL := unsigned(Cfg_AbsLimit);
                if V_v.AbsL > 2 ** AbsBitDepth_g - 1 then
                    V_v.AbsL := to_unsigned(2 ** AbsBitDepth_g - 1, 16);
                end if;
            end if;
            V_v.RelL := (others => '0');
            if UseRel_c then
                V_v.RelL := unsigned(Cfg_RelLimit);
                if V_v.RelL > 2 ** RelBitDepth_g - 1 then
                    V_v.RelL := to_unsigned(2 ** RelBitDepth_g - 1, 16);
                end if;
            end if;
            Lim <= V_v;
        end process;

        -- Active configuration (the values taken for the last image) and the configuration queue
        p_cfg : process (Clk) is
        begin
            if rising_edge(Clk) then
                if Take = '1' then
                    Act                                <= Lim;
                    Queue(to_integer(QWr(3 downto 0))) <= Lim;
                    QWr                                <= QWr + 1;
                end if;
                if Hdr_Valid = '1' and Hdr_Ready = '1' and Hdr_Last = '1' then
                    QRdH <= QRdH + 1;
                end if;
                if HybDone = '1' then
                    QRdC <= QRdC + 1;
                end if;
                if Rst = '1' then
                    Act  <= cfgReset;
                    QWr  <= (others => '0');
                    QRdH <= (others => '0');
                    QRdC <= (others => '0');
                end if;
            end if;
        end process;

        HeadH <= Queue(to_integer(QRdH(3 downto 0)));
        HeadC <= Queue(to_integer(QRdC(3 downto 0)));

        -- Room in the queue for the next image (with the runtime parameters also behind the read pointer of the
        -- sample-adaptive and the block-adaptive coder, g_params)
        g_ready : if not RuntimeParams_g generate
            CfgReady <= '0' when QWr - QRdH = QDepth_c or (Coder_c = CoderHybrid_c and QWr - QRdC = QDepth_c) else '1';
        end generate;

        Cfg_Taken    <= Take;
        Act_XSize    <= std_logic_vector(Act.X);
        Act_YSize    <= std_logic_vector(Act.Y);
        Act_ZSize    <= std_logic_vector(Act.Z);
        Act_AbsLimit <= std_logic_vector(Act.AbsL);
        Act_RelLimit <= std_logic_vector(Act.RelL);

        -- synthesis translate_off
        p_check : process (Clk) is
        begin
            if rising_edge(Clk) then
                if Take = '1' and Rst = '0' then
                    assert unsigned(Cfg_XSize) = Lim.X and unsigned(Cfg_YSize) = Lim.Y and
                           unsigned(Cfg_ZSize) = Lim.Z and
                           (not UseAbs_c or unsigned(Cfg_AbsLimit) = Lim.AbsL) and
                           (not UseRel_c or unsigned(Cfg_RelLimit) = Lim.RelL)
                        report "ocp_core: configuration input out of range, taken as the nearest valid value " &
                               "(CO-RC-07)"
                        severity warning;
                end if;
            end if;
        end process;

        -- synthesis translate_on

    end generate;

    g_constant : if not RuntimeConfig_g generate
        Lim          <= cfgReset;
        Act          <= cfgReset;
        HeadH        <= cfgReset;
        HeadC        <= cfgReset;
        CfgReady     <= '1';
        Cfg_Taken    <= '0';
        Act_XSize    <= (others => '0');
        Act_YSize    <= (others => '0');
        Act_ZSize    <= (others => '0');
        Act_AbsLimit <= (others => '0');
        Act_RelLimit <= (others => '0');
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Runtime parameters
    -----------------------------------------------------------------------------------------------
    g_params : if RuntimeParams_g generate

        -- Range limitation (CO-RP-02): a parameter whose range depends on another one is limited after it, with
        -- its limited value (gamma* after gamma0, vmax after vmin, M after NZ)
        p_param_limit : process (all) is
            variable P_v    : Par_r;
            variable MMax_v : natural range 1 to 65536;
        begin
            P_v      := parReset;
            P_v.User := to_integer(unsigned(Cfg_UserData));
            if UseM_c then
                MMax_v := SubFrameDepth_g;
                if Lim.Z < SubFrameDepth_g then
                    MMax_v := to_integer(Lim.Z);
                end if;
                P_v.M := limitInt(to_integer(unsigned(Cfg_M)), 1, MMax_v);
            end if;
            P_v.TInc := limitInt(to_integer(unsigned(Cfg_WeightInterval)), 4, 11);
            P_v.Vmin := limitInt(to_integer(signed(Cfg_WeightVmin)), -6, 9);
            P_v.Vmax := limitInt(to_integer(signed(Cfg_WeightVmax)), P_v.Vmin, 9);
            if UseAdp_c then
                P_v.Umax  := limitInt(to_integer(unsigned(Cfg_UnaryLimit)), 8, 32);
                P_v.G0    := limitInt(to_integer(unsigned(Cfg_InitCountExp)), G0Min_c,
                                      minimum(8, RescaleCounterSize_g - 1));
                P_v.GStar := limitInt(to_integer(unsigned(Cfg_RescaleSize)), maximum(4, P_v.G0 + 1),
                                      RescaleCounterSize_g);
            end if;
            if UseK_c then
                P_v.K := limitInt(to_integer(unsigned(Cfg_AccuInit)), 0, minimum(DynamicRange_g - 2, 14));
            end if;
            if UseR_c then
                P_v.R := limitInt(to_integer(unsigned(Cfg_RefInterval)), 1, RefInterval_g);
            end if;
            LimPar <= P_v;
        end process;

        -- Active parameters and the queue, both in the encoding of the header fields (CO-RP-05); the read
        -- pointer of the sample-adaptive and the block-adaptive coder moves on after the last item of an image
        p_param : process (Clk) is
        begin
            if rising_edge(Clk) then
                if Take = '1' then
                    ParAct                              <= pack(encode(LimPar));
                    PQueue(to_integer(QWr(3 downto 0))) <= pack(encode(LimPar));
                end if;
                if Item_Valid = '1' and Item_Ready = '1' and Item_Last = '1' then
                    QRdE <= QRdE + 1;
                end if;
                if Rst = '1' then
                    ParAct <= pack(encode(parReset));
                    QRdE   <= (others => '0');
                end if;
            end if;
        end process;

        HeadPH <= unpack(PQueue(to_integer(QRdH(3 downto 0))));
        HeadPC <= decode(unpack(PQueue(to_integer(QRdC(3 downto 0)))));
        HeadPE <= decode(unpack(PQueue(to_integer(QRdE(3 downto 0)))));

        -- Room in the queue: the read pointer of the header generator, of the hybrid coder (its tail) or of the other
        -- coders, which can be one image behind the header generator
        CfgReady <= '0' when QWr - QRdH = QDepth_c or (Coder_c = CoderHybrid_c and QWr - QRdC = QDepth_c) or
                             (Coder_c /= CoderHybrid_c and QWr - QRdE = QDepth_c) else
                    '1';
        ActPar   <= decode(unpack(ParAct));

        Act_UserData       <= std_logic_vector(to_unsigned(ActPar.User, 8));
        Act_M              <= std_logic_vector(to_unsigned(ActPar.M, 17)) when UseM_c else (others => '0');
        Act_WeightInterval <= std_logic_vector(to_unsigned(ActPar.TInc, 4));
        Act_WeightVmin     <= std_logic_vector(to_signed(ActPar.Vmin, 5));
        Act_WeightVmax     <= std_logic_vector(to_signed(ActPar.Vmax, 5));
        Act_UnaryLimit     <= std_logic_vector(to_unsigned(ActPar.Umax, 6)) when UseAdp_c else (others => '0');
        Act_InitCountExp   <= std_logic_vector(to_unsigned(ActPar.G0, 4)) when UseAdp_c else (others => '0');
        Act_RescaleSize    <= std_logic_vector(to_unsigned(ActPar.GStar, 4)) when UseAdp_c else (others => '0');
        Act_AccuInit       <= std_logic_vector(to_unsigned(ActPar.K, 4)) when UseK_c else (others => '0');
        Act_RefInterval    <= std_logic_vector(to_unsigned(ActPar.R, 13)) when UseR_c else (others => '0');

        -- synthesis translate_off
        p_param_check : process (Clk) is
        begin
            if rising_edge(Clk) then
                if Take = '1' and Rst = '0' then
                    assert unsigned(Cfg_UserData) = LimPar.User and
                           (not UseM_c or unsigned(Cfg_M) = LimPar.M) and
                           unsigned(Cfg_WeightInterval) = LimPar.TInc and
                           signed(Cfg_WeightVmin) = LimPar.Vmin and signed(Cfg_WeightVmax) = LimPar.Vmax and
                           (not UseAdp_c or (unsigned(Cfg_UnaryLimit) = LimPar.Umax and
                                             unsigned(Cfg_InitCountExp) = LimPar.G0 and
                                             unsigned(Cfg_RescaleSize) = LimPar.GStar)) and
                           (not UseK_c or unsigned(Cfg_AccuInit) = LimPar.K) and
                           (not UseR_c or unsigned(Cfg_RefInterval) = LimPar.R)
                        report "ocp_core: runtime parameter input out of range, taken as the nearest valid value " &
                               "(CO-RP-02)"
                        severity warning;
                end if;
            end if;
        end process;

        -- synthesis translate_on

    end generate;

    g_no_params : if not RuntimeParams_g generate
        LimPar             <= parReset;
        QRdE               <= (others => '0');
        HeadPH             <= encode(parReset);
        HeadPC             <= parReset;
        HeadPE             <= parReset;
        ActPar             <= parReset;
        Act_UserData       <= (others => '0');
        Act_M              <= (others => '0');
        Act_WeightInterval <= (others => '0');
        Act_WeightVmin     <= (others => '0');
        Act_WeightVmax     <= (others => '0');
        Act_UnaryLimit     <= (others => '0');
        Act_InitCountExp   <= (others => '0');
        Act_RescaleSize    <= (others => '0');
        Act_AccuInit       <= (others => '0');
        Act_RefInterval    <= (others => '0');
    end generate;

    -- Runtime parameters on the ports of the units
    PredM      <= std_logic_vector(to_unsigned(LimPar.M, 17));
    PredTInc   <= std_logic_vector(to_unsigned(LimPar.TInc, 4));
    PredVmin   <= std_logic_vector(to_signed(LimPar.Vmin, 5));
    PredVmax   <= std_logic_vector(to_signed(LimPar.Vmax, 5));
    CoderUmax  <= std_logic_vector(to_unsigned(HeadPE.Umax, 6));
    CoderG0    <= std_logic_vector(to_unsigned(HeadPE.G0, 4));
    CoderGStar <= std_logic_vector(to_unsigned(HeadPE.GStar, 4));
    CoderK     <= std_logic_vector(to_unsigned(HeadPE.K, 4));
    CoderR     <= std_logic_vector(to_unsigned(HeadPE.R, 13));
    HybUmax    <= std_logic_vector(to_unsigned(HeadPC.Umax, 6));
    HybG0      <= std_logic_vector(to_unsigned(HeadPC.G0, 4));
    HybGStar   <= std_logic_vector(to_unsigned(HeadPC.GStar, 4));

    -----------------------------------------------------------------------------------------------
    -- Image framing
    -----------------------------------------------------------------------------------------------
    g_framer : if UseInLast_g generate

        i_framer : entity work.ocp_image_framer
            generic map (
                XSize_g         => XSize_g,
                YSize_g         => YSize_g,
                ZSize_g         => ZSize_g,
                RuntimeConfig_g => RuntimeConfig_g
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
                Smp_End       => SmpEnd,
                Val_Valid     => ValValid,
                Val_Ready     => ValReady,
                Out_Valid     => OutValid,
                Out_Ready     => Out_Ready,
                Out_Last      => OutLast,
                Out_Error     => Out_Error,
                Ev_ImageError => Ev_ImageError,
                Cfg_Take      => Take,
                Cfg_XSize     => std_logic_vector(Lim.X),
                Cfg_YSize     => std_logic_vector(Lim.Y),
                Cfg_ZSize     => std_logic_vector(Lim.Z)
            );

    end generate;

    g_direct : if not UseInLast_g generate
        SmpValid      <= In_Valid;
        In_Ready      <= SmpReady;
        ValValid      <= Lim_Valid;
        Lim_Ready     <= ValReady;
        SmpEnd        <= '0';
        Out_Error     <= '0';
        Ev_ImageError <= '0';
    end generate;

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
            RefInterval_g          => RefInterval_g,
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g
        )
        port map (
            Clk                => Clk,
            Rst                => Rst,
            Start              => Hdr_Start,
            Out_Valid          => Hdr_Valid,
            Out_Ready          => Hdr_Ready,
            Out_Data           => Hdr_Data,
            Out_Length         => Hdr_Length,
            Out_Last           => Hdr_Last,
            Cfg_XSize          => std_logic_vector(HeadH.X),
            Cfg_YSize          => std_logic_vector(HeadH.Y),
            Cfg_ZSize          => std_logic_vector(HeadH.Z),
            Cfg_AbsLimit       => std_logic_vector(HeadH.AbsL),
            Cfg_RelLimit       => std_logic_vector(HeadH.RelL),
            Cfg_UserData       => HeadPH.User,
            Cfg_M              => HeadPH.M,
            Cfg_WeightInterval => HeadPH.TInc,
            Cfg_WeightVmin     => HeadPH.Vmin,
            Cfg_WeightVmax     => HeadPH.Vmax,
            Cfg_UnaryLimit     => HeadPH.Umax,
            Cfg_RescaleSize    => HeadPH.GStar,
            Cfg_InitCountExp   => HeadPH.G0,
            Cfg_AccuInit       => HeadPH.K,
            Cfg_RefInterval    => HeadPH.R
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
            RamStyle_g             => RamStyle_g,
            RuntimeConfig_g        => RuntimeConfig_g,
            RuntimeParams_g        => RuntimeParams_g
        )
        port map (
            Clk                => Clk,
            Rst                => Rst,
            In_Valid           => SmpValid,
            In_Ready           => SmpReady,
            In_Data            => In_Data,
            In_End             => SmpEnd,
            Lim_Valid          => ValValid,
            Lim_Ready          => ValReady,
            Lim_Data           => Lim_Data,
            Cfg_Ready          => CfgReady,
            Cfg_XSize          => std_logic_vector(Lim.X),
            Cfg_YSize          => std_logic_vector(Lim.Y),
            Cfg_ZSize          => std_logic_vector(Lim.Z),
            Cfg_AbsLimit       => std_logic_vector(Lim.AbsL),
            Cfg_RelLimit       => std_logic_vector(Lim.RelL),
            Cfg_M              => PredM,
            Cfg_WeightInterval => PredTInc,
            Cfg_WeightVmin     => PredVmin,
            Cfg_WeightVmax     => PredVmax,
            Cfg_Take           => Take,
            Img_Start          => ImgStart,
            Out_Valid          => Item_Valid,
            Out_Ready          => Item_Ready,
            Out_Data           => Item_Data,
            Out_Kind           => Item_Kind,
            Out_Band           => Item_Band,
            Out_First          => Item_First,
            Out_Init           => Item_Init,
            Out_Last           => Item_Last,
            Ecc_Sec            => PredSec,
            Ecc_Ded            => PredDed,
            ErrInj_Channel     => ErrInj_Channel,
            ErrInj_Double      => ErrInj_Double,
            ErrInj_Valid       => ErrInj_Valid
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
                RamStyle_g            => RamStyle_g,
                RuntimeParams_g       => RuntimeParams_g
            )
            port map (
                Clk             => Clk,
                Rst             => Rst,
                In_Valid        => Item_Valid,
                In_Ready        => Item_Ready,
                In_Data         => Item_Data,
                In_Kind         => Item_Kind,
                In_Band         => Item_Band,
                In_First        => Item_First,
                In_Init         => Item_Init,
                In_Last         => Item_Last,
                In_UnaryLimit   => CoderUmax,
                In_InitCountExp => CoderG0,
                In_RescaleSize  => CoderGStar,
                In_AccuInit     => CoderK,
                Cw_Valid        => Cw_Valid,
                Cw_Ready        => Cw_Ready,
                Cw_Data         => Cw_Data,
                Cw_Length       => Cw_Length,
                Cw_Last         => Cw_Last,
                Ecc_Sec         => CoderSec,
                Ecc_Ded         => CoderDed,
                ErrInj_Stats    => InjStats,
                ErrInj_Buffer   => InjBuffer,
                ErrInj_Double   => ErrInj_Double
            );

    end generate;

    g_no_hybrid : if Coder_c /= CoderHybrid_c generate
        HybDone <= '0';
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
                RamStyle_g           => RamStyle_g,
                RuntimeConfig_g      => RuntimeConfig_g,
                RuntimeParams_g      => RuntimeParams_g
            )
            port map (
                Clk              => Clk,
                Rst              => Rst,
                In_Valid         => Item_Valid,
                In_Ready         => Item_Ready,
                In_Data          => Item_Data,
                In_Kind          => Item_Kind,
                In_Band          => Item_Band,
                In_First         => Item_First,
                In_Init          => Item_Init,
                In_Last          => Item_Last,
                Cw_Valid         => Cw_Valid,
                Cw_Ready         => Cw_Ready,
                Cw_Data          => Cw_Data,
                Cw_Length        => Cw_Length,
                Cw_Last          => Cw_Last,
                Ecc_Sec          => CoderSec,
                Ecc_Ded          => CoderDed,
                ErrInj_Stats     => InjStats,
                ErrInj_Buffer    => InjBuffer,
                ErrInj_Double    => ErrInj_Double,
                Cfg_ZSize        => std_logic_vector(HeadC.Z),
                Cfg_UnaryLimit   => HybUmax,
                Cfg_InitCountExp => HybG0,
                Cfg_RescaleSize  => HybGStar,
                Cfg_Done         => HybDone
            );

    end generate;

    g_block : if Coder_c = CoderBlock_c generate

        i_coder : entity work.ocp_block_adaptive_coder
            generic map (
                DynamicRange_g    => DynamicRange_g,
                BlockSize_g       => BlockSize_g,
                RestrictedCodes_g => RestrictedCodes_g,
                RefInterval_g     => RefInterval_g,
                RamStyle_g        => RamStyle_g,
                RuntimeParams_g   => RuntimeParams_g
            )
            port map (
                Clk            => Clk,
                Rst            => Rst,
                In_Valid       => Item_Valid,
                In_Ready       => Item_Ready,
                In_Data        => Item_Data,
                In_Last        => Item_Last,
                In_RefInterval => CoderR,
                Cw_Valid       => Cw_Valid,
                Cw_Ready       => Cw_Ready,
                Cw_Data        => Cw_Data,
                Cw_Length      => Cw_Length,
                Cw_Last        => Cw_Last,
                Ecc_Sec        => CoderSec,
                Ecc_Ded        => CoderDed,
                ErrInj_Buffer  => InjBuffer,
                ErrInj_Double  => ErrInj_Double
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
