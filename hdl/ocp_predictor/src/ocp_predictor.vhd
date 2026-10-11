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
-- values. One sample is processed at a time; sample representatives, local differences and weights
-- are kept in SECDED-protected memories.
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
        RamStyle_g             : string                    := "auto"
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Image samples in the input order
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Data   : in    std_logic_vector(DynamicRange_g - 1 downto 0);
        -- Error limit values for periodic error limit updating (entropy coder input order)
        Lim_Valid : in    std_logic                     := '0';
        Lim_Ready : out   std_logic;
        Lim_Data  : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Entropy coder input sequence
        Out_Valid : out   std_logic;
        Out_Ready : in    std_logic;
        Out_Data  : out   std_logic_vector(maximum(DynamicRange_g, 16) - 1 downto 0);
        Out_Kind  : out   std_logic_vector(1 downto 0);
        Out_Band  : out   std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
        Out_First : out   std_logic;
        Out_Init  : out   std_logic;
        Out_Last  : out   std_logic;
        -- Memory errors (pulses): corrected single error, detected double error
        Ecc_Sec   : out   std_logic;
        Ecc_Ded   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_predictor is

    -- Configuration
    constant D_c        : positive := DynamicRange_g;
    constant Om_c       : positive := WeightResolution_g;
    constant P_c        : natural  := PredictionBands_g;
    constant Order_c    : natural  := encodingOrderCode(EncodingOrder_g);
    constant Bsq_c      : boolean  := Order_c = OrderBsq_c;
    constant Sum_c      : natural  := localSumCode(LocalSum_g);
    constant Narrow_c   : boolean  := Sum_c = SumNarrowNeighbor_c or Sum_c = SumNarrowColumn_c;
    constant Full_c     : boolean  := fullPrediction(PredictionMode_g);
    constant Fid_c      : natural  := fidelityCode(Fidelity_g);
    constant UseAbs_c   : boolean  := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
    constant UseRel_c   : boolean  := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
    constant Periodic_c : boolean  := PeriodicUpdate_g and Fid_c /= FidLossless_c and not Bsq_c;
    constant Theta_c    : natural  := SampleRepResolution_g;
    constant M_c        : positive := minimum(SubFrameDepth_g, ZSize_g);
    constant Cmax_c     : natural  := P_c + 3 * toInt(Full_c);

    -- Widths: samples, local differences (and their storage), weights, dot product, high-resolution
    -- predicted sample, quantizer operands, sample representative numerator
    constant SW_c      : positive := D_c + 2;
    constant DW_c      : positive := D_c + 4;
    constant DWs_c     : positive := D_c + 3;
    constant WW_c      : positive := Om_c + 3;
    constant AccW_c    : positive := Om_c + D_c + 12;
    constant HW_c      : positive := maximum(RegisterSize_g, AccW_c) + 3;
    constant STildeW_c : positive := Om_c + D_c + 6;
    constant QW_c      : positive := maximum(D_c, 16) + 2;
    constant RW_c      : positive := SW_c + Om_c + 12;
    constant OutW_c    : positive := maximum(D_c, 16);

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

    -- Memories: sample representatives of the current and the previous line(s), central local
    -- differences of the last P bands per pixel, weight vectors per band
    constant SrSlots_c   : positive := 2 * ZSize_g * toInt(not Bsq_c) + 6 * toInt(Bsq_c);
    constant SrDepth_c   : positive := SrSlots_c * XSize_g;
    constant DiffDepth_c : positive := XSize_g * toInt(not Bsq_c) + XSize_g * YSize_g * toInt(Bsq_c);
    constant WDepth_c    : positive := maximum(ZSize_g * toInt(not Bsq_c), 2);
    constant DiffBits_c  : positive := maximum(P_c, 1) * DWs_c;
    constant WBits_c     : positive := maximum(Cmax_c, 1) * WW_c;

    type SampleArr_t is array (natural range <>) of signed(SW_c - 1 downto 0);
    type DiffArr_t is array (natural range <>) of signed(DW_c - 1 downto 0);
    type WeightArr_t is array (natural range <>) of signed(WW_c - 1 downto 0);
    type ZetaArr_t is array (natural range <>) of signed(3 downto 0);
    type QuoArr_t is array (0 to 2) of unsigned(QW_c - 1 downto 0);
    type RemArr_t is array (0 to 2) of unsigned(18 downto 0);

    -- Initial weight vector W_z(1) of band z (CCSDS 4.6.3)
    function initWeights (z : natural) return WeightArr_t is
        variable W_v     : WeightArr_t(0 to maximum(Cmax_c, 1) - 1) := (others => (others => '0'));
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
    type ZetaRom_t is array (0 to ZSize_g - 1) of std_logic_vector(maximum(Cmax_c, 1) * 4 - 1 downto 0);

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
        variable W_v : WeightArr_t(0 to maximum(Cmax_c, 1) - 1);
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

            for j in 0 to maximum(Cmax_c, 1) - 1 loop
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

    type Fsm_t is (
        Idle_s, LimIn_s, LimOut_s, Fetch_s, Sum_s, Dot_s, DotLast_s, Pred_s, Quant_s, Div_s, Rep_s, RepMul_s,
        RepSum_s, Map_s, Update_s, UpdateLast_s, Out_s
    );

    type TwoProcess_r is record
        Fsm      : Fsm_t;
        -- Position in the input order
        X        : unsigned(XW_c - 1 downto 0);
        Y        : unsigned(YW_c - 1 downto 0);
        Z        : unsigned(ZW_c - 1 downto 0);
        SubLow   : unsigned(ZW_c - 1 downto 0);
        RowBase  : unsigned(TW_c - 1 downto 0);
        LimDone  : std_logic;
        -- Current sample
        Sample   : signed(SW_c - 1 downto 0);
        T        : unsigned(TW_c - 1 downto 0);
        First    : std_logic;
        Init     : std_logic;
        LastSmp  : std_logic;
        RdIdx    : natural range 0 to 5;
        Nb       : SampleArr_t(0 to 3);
        DiffWord : std_logic_vector(DiffBits_c - 1 downto 0);
        Wgt      : WeightArr_t(0 to maximum(Cmax_c, 1) - 1);
        Zeta     : ZetaArr_t(0 to maximum(Cmax_c, 1) - 1);
        AbsLim   : unsigned(15 downto 0);
        RelLim   : unsigned(15 downto 0);
        Sigma    : signed(SW_c + 2 downto 0);
        U        : DiffArr_t(0 to maximum(Cmax_c, 1) - 1);
        J        : natural range 0 to maximum(Cmax_c, 1);
        Acc      : signed(AccW_c - 1 downto 0);
        Prod     : signed(WW_c + DW_c - 1 downto 0);
        ProdVal  : std_logic;
        STilde   : signed(STildeW_c - 1 downto 0);
        SDbl     : signed(SW_c downto 0);
        SHat     : signed(SW_c - 1 downto 0);
        Res      : signed(SW_c downto 0);
        M        : unsigned(15 downto 0);
        Divisor  : unsigned(17 downto 0);
        Dvd      : QuoArr_t;
        Quo      : QuoArr_t;
        Remd     : RemArr_t;
        DivCnt   : natural range 0 to QW_c;
        Q        : signed(QW_c downto 0);
        ThetaM   : unsigned(QW_c - 1 downto 0);
        SClip    : signed(SW_c - 1 downto 0);
        Phi      : natural range 0 to 15;
        Psi      : natural range 0 to 15;
        Corr     : signed(RW_c - 1 downto 0);
        Num1     : signed(RW_c - 1 downto 0);
        Num2     : signed(RW_c - 1 downto 0);
        SRep     : signed(SW_c - 1 downto 0);
        Dz       : signed(DW_c - 1 downto 0);
        E        : signed(SW_c + 1 downto 0);
        Rho      : integer range -32 to 63;
        Inc      : signed(WW_c + 1 downto 0);
        IncIdx   : natural range 0 to maximum(Cmax_c, 1) - 1;
        IncVal   : std_logic;
        Delta    : unsigned(D_c - 1 downto 0);
        -- Error limit update
        LimIdx   : natural range 0 to 2 * ZSize_g;
        LimVal   : unsigned(15 downto 0);
        LimKind  : std_logic_vector(1 downto 0);
        AbsConst : unsigned(15 downto 0);
        RelConst : unsigned(15 downto 0);
        -- Output
        OutValid : std_logic;
        OutData  : std_logic_vector(OutW_c - 1 downto 0);
        OutKind  : std_logic_vector(1 downto 0);
        OutBand  : std_logic_vector(ZW_c - 1 downto 0);
        OutFirst : std_logic;
        OutInit  : std_logic;
        OutLast  : std_logic;
        EccSec   : std_logic;
        EccDed   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Memory ports
    signal SrRdAddr   : std_logic_vector(log2ceil(SrDepth_c) - 1 downto 0);
    signal SrRdData   : std_logic_vector(D_c - 1 downto 0);
    signal SrWrAddr   : std_logic_vector(log2ceil(SrDepth_c) - 1 downto 0);
    signal SrWrEna    : std_logic;
    signal SrWrData   : std_logic_vector(D_c - 1 downto 0);
    signal DiffRdAddr : std_logic_vector(log2ceil(DiffDepth_c) - 1 downto 0);
    signal DiffRdData : std_logic_vector(DiffBits_c - 1 downto 0);
    signal DiffWrEna  : std_logic;
    signal DiffWrData : std_logic_vector(DiffBits_c - 1 downto 0);
    signal WRdAddr    : std_logic_vector(log2ceil(WDepth_c) - 1 downto 0);
    signal WRdData    : std_logic_vector(WBits_c - 1 downto 0);
    signal WWrEna     : std_logic;
    signal WWrData    : std_logic_vector(WBits_c - 1 downto 0);
    signal LimRdAddr  : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
    signal LimWrAddr  : std_logic_vector(log2ceil(ZSize_g + 1) - 1 downto 0);
    signal AbsWrEna   : std_logic;
    signal RelWrEna   : std_logic;
    signal AbsRdData  : std_logic_vector(15 downto 0);
    signal RelRdData  : std_logic_vector(15 downto 0);
    signal EccSecVec  : std_logic_vector(4 downto 0);
    signal EccDedVec  : std_logic_vector(4 downto 0);

    -- Address of the sample representative of (z, y, x): BI keeps two lines of every band, BSQ keeps
    -- row 0 and two further rows of the current and the previous band
    function srAddr (z : unsigned; y : unsigned; x : unsigned) return std_logic_vector is
        variable Slot_v : natural;
    begin
        if Bsq_c then
            if y = 0 then
                Slot_v := 2;
            else
                Slot_v := to_integer(y(0 downto 0));
            end if;
            Slot_v := 3 * to_integer(z(0 downto 0)) + Slot_v;
        else
            Slot_v := 2 * to_integer(z) + to_integer(y(0 downto 0));
        end if;
        return std_logic_vector(to_unsigned(Slot_v * XSize_g + to_integer(x), log2ceil(SrDepth_c)));
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
    assert not (PeriodicUpdate_g and Bsq_c and Fid_c /= FidLossless_c)
        report "ocp_predictor: periodic error limit updating is not allowed with BSQ order (CCSDS 4.8.2.4.4)"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Combinational process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v        : TwoProcess_r;
        variable Zi_v     : natural;
        variable Xi_v     : natural;
        variable Yi_v     : natural;
        variable XLast_v  : boolean;
        variable ZLast_v  : boolean;
        variable N_v      : signed(SW_c - 1 downto 0);
        variable NW_v     : signed(SW_c - 1 downto 0);
        variable NE_v     : signed(SW_c - 1 downto 0);
        variable Alt_v    : signed(SW_c - 1 downto 0);
        variable Sig_v    : signed(SW_c + 2 downto 0);
        variable H_v      : signed(HW_c - 1 downto 0);
        variable Mod_v    : signed(HW_c - 1 downto 0);
        variable AbsRes_v : unsigned(QW_c - 1 downto 0);
        variable RelM_v   : unsigned(SW_c + 16 downto 0);
        variable M_v      : unsigned(15 downto 0);
        variable Corr_v   : signed(RW_c - 1 downto 0);
        variable SRep2_v  : signed(RW_c - 1 downto 0);
        variable SPrime_v : signed(SW_c + 1 downto 0);
        variable QAbs_v   : unsigned(QW_c - 1 downto 0);
        variable QAbsS_v  : signed(QW_c downto 0);
        variable Th1_v    : unsigned(QW_c - 1 downto 0);
        variable Th2_v    : unsigned(QW_c - 1 downto 0);
        variable Par_v    : signed(QW_c downto 0);
        variable Rem_v    : unsigned(18 downto 0);
        variable Shift_v  : integer range -64 to 63;
        variable Val_v    : signed(DW_c downto 0);
        variable Inc_v    : signed(WW_c + 1 downto 0);
        variable Big_v    : signed(DW_c + WW_c + 4 downto 0);
        variable Sat_v    : boolean;
        variable Wn_v     : signed(WW_c + 2 downto 0);
        variable Tm_v     : signed(TW_c downto 0);
        variable Rho_v    : integer range -64 to 63;
        variable Word_v   : std_logic_vector(DiffBits_c - 1 downto 0);
        variable NA_v     : natural range 0 to 65536;
        variable NR_v     : natural range 0 to 65536;
    begin
        v := r;

        -- Defaults of the memory and handshake signals
        In_Ready  <= '0';
        Lim_Ready <= '0';
        SrRdAddr  <= (others => '0');
        SrWrAddr  <= srAddr(r.Z, r.Y, r.X);
        SrWrEna   <= '0';
        SrWrData  <= std_logic_vector(r.SRep(D_c - 1 downto 0));
        DiffWrEna <= '0';
        WWrEna    <= '0';
        LimWrAddr <= (others => '0');
        AbsWrEna  <= '0';
        RelWrEna  <= '0';
        v.EccSec  := or(EccSecVec);
        v.EccDed  := or(EccDedVec);

        if Out_Ready = '1' then
            v.OutValid := '0';
        end if;

        Zi_v    := to_integer(r.Z);
        Xi_v    := to_integer(r.X);
        Yi_v    := to_integer(r.Y);
        XLast_v := Xi_v = XSize_g - 1;
        ZLast_v := Zi_v = ZSize_g - 1;

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

        case r.Fsm is

            -- Wait for a sample, or read new error limits at the start of a frame
            when Idle_s =>
                if Periodic_c and r.LimDone = '0' and r.X = 0 and r.Z = 0 and r.SubLow = 0 and
                   (r.Y mod 2 ** UpdatePeriodExp_g) = 0 then
                    v.LimIdx := 0;
                    v.Fsm    := LimIn_s;
                else
                    In_Ready <= '1';
                    if In_Valid = '1' then
                        v.Sample := toSample(In_Data);
                        v.T      := r.RowBase + resize(r.X, TW_c);
                        v.First  := toSl(r.RowBase = 0 and r.X = 0);
                        v.Init   := toSl(r.RowBase + resize(r.X, TW_c) = 1);
                        v.RdIdx  := 0;
                        v.Fsm    := Fetch_s;
                        if Bsq_c then
                            v.LastSmp := toSl(ZLast_v and Yi_v = YSize_g - 1 and XLast_v);
                        else
                            v.LastSmp := toSl(Yi_v = YSize_g - 1 and XLast_v and ZLast_v);
                        end if;
                    end if;
                end if;

            -- Periodic error limit updating (CCSDS 4.8.2.4): read the values and forward them
            when LimIn_s =>
                Lim_Ready <= '1';
                if Lim_Valid = '1' then
                    v.LimVal := unsigned(Lim_Data);
                    if r.LimIdx < NA_v then
                        v.LimKind := ItemAbsLimit_c;
                        if AbsBandDependent_g then
                            AbsWrEna <= '1';
                        else
                            v.AbsConst := unsigned(Lim_Data);
                        end if;
                    else
                        v.LimKind := ItemRelLimit_c;
                        if RelBandDependent_g then
                            RelWrEna <= '1';
                        else
                            v.RelConst := unsigned(Lim_Data);
                        end if;
                    end if;
                    if r.LimIdx < NA_v then
                        LimWrAddr <= std_logic_vector(to_unsigned(r.LimIdx, LimWrAddr'length));
                    else
                        LimWrAddr <= std_logic_vector(to_unsigned(r.LimIdx - NA_v, LimWrAddr'length));
                    end if;
                    v.Fsm := LimOut_s;
                end if;

            when LimOut_s =>
                if r.OutValid = '0' or Out_Ready = '1' then
                    v.OutValid := '1';
                    v.OutData  := std_logic_vector(resize(r.LimVal, OutW_c));
                    v.OutKind  := r.LimKind;
                    v.OutBand  := (others => '0');
                    v.OutFirst := '0';
                    v.OutInit  := '0';
                    v.OutLast  := '0';
                    if r.LimIdx = NA_v + NR_v - 1 then
                        v.LimDone := '1';
                        v.Fsm     := Idle_s;
                    else
                        v.LimIdx := r.LimIdx + 1;
                        v.Fsm    := LimIn_s;
                    end if;
                end if;

            -- Read the neighbors (N, NW, NE, W or the previous band), the local differences of the
            -- previous bands, the weights and the error limits
            when Fetch_s =>

                -- Neighbors outside the image are not read (their values are not used)
                case r.RdIdx is
                    when 0 =>
                        if r.Y > 0 then
                            SrRdAddr <= srAddr(r.Z, r.Y - 1, r.X);
                        end if;
                    when 1 =>
                        if r.Y > 0 and r.X > 0 then
                            SrRdAddr <= srAddr(r.Z, r.Y - 1, r.X - 1);
                        end if;
                    when 2 =>
                        if r.Y > 0 and not XLast_v then
                            SrRdAddr <= srAddr(r.Z, r.Y - 1, r.X + 1);
                        end if;
                    when 3 =>
                        if r.First = '1' then
                            -- Sample of the previous band at t = 0 (4.7.3)
                            if r.Z > 0 then
                                SrRdAddr <= srAddr(r.Z - 1, r.Y, r.X);
                            end if;
                        elsif r.Y = 0 and Narrow_c then
                            -- Narrow local sums in the first row: previous band (4.4)
                            if r.Z > 0 and r.X > 0 then
                                SrRdAddr <= srAddr(r.Z - 1, r.Y, r.X - 1);
                            end if;
                        elsif r.X > 0 then
                            SrRdAddr <= srAddr(r.Z, r.Y, r.X - 1);
                        end if;
                    when others =>
                        null;
                end case;

                if r.RdIdx > 0 then
                    v.Nb(r.RdIdx - 1) := toSample(SrRdData);
                end if;
                if r.RdIdx = 1 then
                    v.DiffWord := DiffRdData;
                    if r.Init = '1' then

                        for j in 0 to maximum(Cmax_c, 1) - 1 loop
                            v.Wgt(j) := signed(WeightRom_c(Zi_v)((j + 1) * WW_c - 1 downto j * WW_c));
                        end loop;

                    else

                        for j in 0 to maximum(Cmax_c, 1) - 1 loop
                            v.Wgt(j) := signed(WRdData((j + 1) * WW_c - 1 downto j * WW_c));
                        end loop;

                    end if;

                    for j in 0 to maximum(Cmax_c, 1) - 1 loop
                        v.Zeta(j) := signed(ZetaRom_c(Zi_v)((j + 1) * 4 - 1 downto j * 4));
                    end loop;

                    -- Damping and offset of the band (sample representatives with Theta > 0 only)
                    v.Phi := 0;
                    v.Psi := 0;
                    if Theta_c > 0 then
                        v.Phi := PhiRom_c(Zi_v);
                        v.Psi := PsiRom_c(Zi_v);
                    end if;

                    if Periodic_c then
                        if AbsBandDependent_g then
                            v.AbsLim := unsigned(AbsRdData);
                        else
                            v.AbsLim := r.AbsConst;
                        end if;
                        if RelBandDependent_g then
                            v.RelLim := unsigned(RelRdData);
                        else
                            v.RelLim := r.RelConst;
                        end if;
                    else
                        v.AbsLim := to_unsigned(AbsRom_c(Zi_v), 16);
                        v.RelLim := to_unsigned(RelRom_c(Zi_v), 16);
                    end if;
                end if;
                if r.RdIdx = 4 then
                    v.Fsm := Sum_s;
                else
                    v.RdIdx := r.RdIdx + 1;
                end if;

            -- Local sum (CCSDS 4.4) and local difference vector (4.5)
            when Sum_s =>
                N_v   := r.Nb(0);
                NW_v  := r.Nb(1);
                NE_v  := r.Nb(2);
                Alt_v := r.Nb(3);
                Sig_v := (others => '0');

                case Sum_c is
                    when SumWideNeighbor_c =>
                        if r.Y > 0 and r.X > 0 and not XLast_v then
                            Sig_v := resize(Alt_v, Sig_v'length) + NW_v + N_v + NE_v;
                        elsif r.Y = 0 then
                            Sig_v := shift_left(resize(Alt_v, Sig_v'length), 2);
                        elsif r.X = 0 then
                            Sig_v := shift_left(resize(N_v, Sig_v'length) + NE_v, 1);
                        else
                            Sig_v := resize(Alt_v, Sig_v'length) + NW_v + shift_left(resize(N_v, Sig_v'length), 1);
                        end if;
                    when SumNarrowNeighbor_c =>
                        if r.Y > 0 and r.X > 0 and not XLast_v then
                            Sig_v := resize(NW_v, Sig_v'length) + shift_left(resize(N_v, Sig_v'length), 1) + NE_v;
                        elsif r.Y = 0 then
                            if r.Z > 0 then
                                Sig_v := shift_left(resize(Alt_v, Sig_v'length), 2);
                            else
                                Sig_v := shift_left(resize(SMid_c, Sig_v'length), 2);
                            end if;
                        elsif r.X = 0 then
                            Sig_v := shift_left(resize(N_v, Sig_v'length) + NE_v, 1);
                        else
                            Sig_v := shift_left(resize(NW_v, Sig_v'length) + N_v, 1);
                        end if;
                    when SumWideColumn_c =>
                        if r.Y > 0 then
                            Sig_v := shift_left(resize(N_v, Sig_v'length), 2);
                        else
                            Sig_v := shift_left(resize(Alt_v, Sig_v'length), 2);
                        end if;
                    when others =>
                        if r.Y > 0 then
                            Sig_v := shift_left(resize(N_v, Sig_v'length), 2);
                        elsif r.Z > 0 then
                            Sig_v := shift_left(resize(Alt_v, Sig_v'length), 2);
                        else
                            Sig_v := shift_left(resize(SMid_c, Sig_v'length), 2);
                        end if;
                end case;

                v.Sigma := Sig_v;
                v.U     := (others => (others => '0'));
                if Full_c then
                    -- Directional local differences (4.5.2)
                    if r.Y > 0 then
                        v.U(0) := resize(shift_left(resize(N_v, DW_c), 2) - Sig_v, DW_c);
                        if r.X > 0 then
                            v.U(1) := resize(shift_left(resize(Alt_v, DW_c), 2) - Sig_v, DW_c);
                            v.U(2) := resize(shift_left(resize(NW_v, DW_c), 2) - Sig_v, DW_c);
                        else
                            v.U(1) := resize(shift_left(resize(N_v, DW_c), 2) - Sig_v, DW_c);
                            v.U(2) := resize(shift_left(resize(N_v, DW_c), 2) - Sig_v, DW_c);
                        end if;
                    end if;
                end if;

                -- Central local differences of the Pz* previous bands (4.5.3)
                for i in 1 to P_c loop
                    if i <= Zi_v then
                        v.U(3 * toInt(Full_c) + i - 1) := resize(signed(r.DiffWord(i * DWs_c - 1 downto (i - 1) * DWs_c)),
                                                                 DW_c);
                    end if;
                end loop;

                v.J       := 0;
                v.Acc     := (others => '0');
                v.ProdVal := '0';
                if r.First = '1' then
                    v.Fsm := Pred_s;
                elsif Cmax_c = 0 then
                    v.Fsm := Pred_s;
                else
                    v.Fsm := Dot_s;
                end if;

            -- Predicted central local difference (4.7.1), one product per cycle
            when Dot_s =>
                -- Product of component J; the product of component J - 1 is accumulated
                v.Prod    := r.Wgt(r.J) * r.U(r.J);
                v.ProdVal := '1';
                if r.ProdVal = '1' then
                    v.Acc := r.Acc + resize(r.Prod, AccW_c);
                end if;
                if r.J = maximum(Cmax_c, 1) - 1 then
                    v.Fsm := DotLast_s;
                else
                    v.J := r.J + 1;
                end if;

            when DotLast_s =>
                v.Acc     := r.Acc + resize(r.Prod, AccW_c);
                v.ProdVal := '0';
                v.Fsm     := Pred_s;

            -- High-resolution, double-resolution and predicted sample values (4.7.2 to 4.7.4)
            when Pred_s =>
                if r.First = '1' then
                    -- (38): t = 0
                    if P_c > 0 and r.Z > 0 then
                        v.SDbl := shift_left(resize(r.Nb(3), SW_c + 1), 1);
                    else
                        v.SDbl := shift_left(resize(SMid_c, SW_c + 1), 1);
                    end if;
                    v.STilde := (others => '0');
                else
                    H_v := resize(r.Acc, HW_c) + shift_left(resize(r.Sigma, HW_c) - shift_left(resize(SMid_c, HW_c), 2),
                                                            Om_c);
                    -- mod*R (1.6.1): R-bit two's complement wrap
                    Mod_v    := resize(H_v(RegisterSize_g - 1 downto 0), HW_c);
                    Mod_v    := Mod_v + shift_left(resize(SMid_c, HW_c), Om_c + 2) + shift_left(to_signed(1, HW_c), Om_c + 1);
                    Mod_v    := clipSigned(Mod_v, shift_left(resize(SMin_c, HW_c), Om_c + 2),
                                           shift_left(resize(SMax_c, HW_c), Om_c + 2) + shift_left(to_signed(1, HW_c), Om_c + 1));
                    v.STilde := resize(Mod_v, STildeW_c);
                    v.SDbl   := resize(shift_right(Mod_v, Om_c + 1), SW_c + 1);
                end if;
                v.Fsm := Quant_s;

            -- Prediction residual (4.8.1) and maximum error (4.8.2)
            when Quant_s =>
                v.SHat := resize(shift_right(r.SDbl, 1), SW_c);
                v.Res  := resize(r.Sample, SW_c + 1) - shift_right(r.SDbl, 1);
                M_v    := (others => '0');
                if r.First = '0' then
                    RelM_v := shift_right(resize(r.RelLim * unsigned(abs(resize(shift_right(r.SDbl, 1), SW_c + 1))),
                                                 RelM_v'length), D_c);

                    case Fid_c is
                        when FidAbsolute_c =>
                            M_v := r.AbsLim;
                        when FidRelative_c =>
                            M_v := resize(RelM_v, 16);
                        when FidBoth_c =>
                            if RelM_v < r.AbsLim then
                                M_v := resize(RelM_v, 16);
                            else
                                M_v := r.AbsLim;
                            end if;
                        when others =>
                            M_v := (others => '0');
                    end case;

                end if;
                v.M       := M_v;
                v.Divisor := resize(M_v & '1', 18);
                -- Dividends: |residual| + m and the distances of the prediction to the sample limits (56)
                v.Dvd(0) := resize(unsigned(abs(v.Res)), QW_c) + M_v;
                v.Dvd(1) := resize(unsigned(resize(v.SHat, QW_c + 1) - SMin_c), QW_c) + M_v;
                v.Dvd(2) := resize(unsigned(resize(SMax_c, QW_c + 1) - v.SHat), QW_c) + M_v;
                v.Remd   := (others => (others => '0'));
                v.Quo    := (others => (others => '0'));
                v.DivCnt := 0;
                if M_v = 0 or r.First = '1' then
                    v.Quo := v.Dvd;
                    v.Fsm := Rep_s;
                else
                    v.Fsm := Div_s;
                end if;

            -- Restoring division of the three dividends by 2m + 1, one quotient bit per cycle
            when Div_s =>

                for k in 0 to 2 loop
                    Rem_v := r.Remd(k)(17 downto 0) & r.Dvd(k)(QW_c - 1 - r.DivCnt);
                    if Rem_v >= r.Divisor then
                        v.Remd(k)                     := Rem_v - r.Divisor;
                        v.Quo(k)(QW_c - 1 - r.DivCnt) := '1';
                    else
                        v.Remd(k) := Rem_v;
                    end if;
                end loop;

                if r.DivCnt = QW_c - 1 then
                    v.Fsm := Rep_s;
                else
                    v.DivCnt := r.DivCnt + 1;
                end if;

            -- Quantizer index (41), clipped bin center (48), sample representative (46), (47)
            when Rep_s =>
                QAbs_v := r.Quo(0);
                if r.First = '1' then
                    v.Q      := resize(r.Res, QW_c + 1);
                    SPrime_v := resize(r.Sample, SW_c + 2);
                    v.SClip  := r.Sample;
                    v.SRep   := r.Sample;
                    v.Dz     := (others => '0');
                    Th1_v    := r.Quo(1);
                    Th2_v    := r.Quo(2);
                else
                    if r.Res < 0 then
                        v.Q      := -signed(resize(QAbs_v, QW_c + 1));
                        SPrime_v := resize(r.SHat, SW_c + 2) - signed(resize(r.Dvd(0) - resize(r.Remd(0), QW_c), SW_c + 2));
                    else
                        v.Q      := signed(resize(QAbs_v, QW_c + 1));
                        SPrime_v := resize(r.SHat, SW_c + 2) + signed(resize(r.Dvd(0) - resize(r.Remd(0), QW_c), SW_c + 2));
                    end if;
                    SPrime_v := clipSigned(SPrime_v, resize(SMin_c, SW_c + 2), resize(SMax_c, SW_c + 2));
                    v.SClip  := resize(SPrime_v, SW_c);
                    -- sgn(q) m psi 2^(Omega - Theta) of (47)
                    Corr_v := shift_left(resize(signed('0' & r.M) * to_signed(r.Psi, 6), RW_c), Om_c - Theta_c);
                    if v.Q < 0 then
                        Corr_v := -Corr_v;
                    elsif v.Q = 0 then
                        Corr_v := (others => '0');
                    end if;
                    v.Corr := Corr_v;
                    Th1_v  := r.Quo(1);
                    Th2_v  := r.Quo(2);
                end if;
                if Th1_v < Th2_v then
                    v.ThetaM := Th1_v;
                else
                    v.ThetaM := Th2_v;
                end if;
                -- Double-resolution prediction error (49)
                v.E := resize(shift_left(resize(SPrime_v, SW_c + 2), 1), SW_c + 2) - resize(r.SDbl, SW_c + 2);
                -- Weight update scaling exponent (50)
                Tm_v := signed('0' & r.T) - XSize_g;
                Tm_v := shift_right(Tm_v, WeightUpdateInterval_g);
                if Tm_v < 0 then
                    Rho_v := WeightUpdateVmin_g;
                elsif Tm_v > WeightUpdateVmax_g - WeightUpdateVmin_g then
                    Rho_v := WeightUpdateVmax_g;
                else
                    Rho_v := WeightUpdateVmin_g + to_integer(Tm_v);
                end if;
                v.Rho := Rho_v + D_c - Om_c;
                if r.First = '1' then
                    v.Fsm := Map_s;
                else
                    v.Fsm := RepMul_s;
                end if;

            -- Sample representative (47): products of the numerator
            when RepMul_s =>
                v.Num1 := resize(to_signed(4 * (2 ** Theta_c) - 4 * r.Phi, 8) *
                                 (shift_left(resize(r.SClip, RW_c - 8), Om_c) - resize(r.Corr, RW_c - 8)), RW_c);
                v.Num2 := resize(to_signed(r.Phi, 6) * r.STilde, RW_c) - shift_left(to_signed(r.Phi, RW_c), Om_c + 1);
                v.Fsm  := RepSum_s;

            -- Sample representative (46), (47) and central local difference (24)
            when RepSum_s =>
                SRep2_v := shift_right(r.Num1 + r.Num2, Om_c + Theta_c + 1);
                v.SRep  := resize(shift_right(SRep2_v + 1, 1), SW_c);
                v.Dz    := resize(shift_left(resize(v.SRep, DW_c), 2) - r.Sigma, DW_c);
                v.Fsm   := Map_s;

            -- Mapped quantizer index (55)
            when Map_s =>
                QAbsS_v := abs(r.Q);
                QAbs_v  := unsigned(QAbsS_v(QW_c - 1 downto 0));
                if r.SDbl(0) = '1' then
                    Par_v := -r.Q;
                else
                    Par_v := r.Q;
                end if;
                if QAbs_v > r.ThetaM then
                    v.Delta := resize(QAbs_v + r.ThetaM, D_c);
                elsif Par_v >= 0 and Par_v <= signed('0' & r.ThetaM) then
                    v.Delta := resize(shift_left(QAbs_v, 1), D_c);
                else
                    v.Delta := resize(shift_left(QAbs_v, 1) - 1, D_c);
                end if;
                v.J := 0;
                if r.First = '1' or Cmax_c = 0 then
                    v.Fsm := Out_s;
                else
                    v.Fsm := Update_s;
                end if;

            -- Weight update (4.10.3), one component per cycle
            when Update_s =>
                -- Stage 1: increment of component J
                Shift_v := r.Rho + to_integer(r.Zeta(r.J));
                Val_v   := resize(r.U(r.J), DW_c + 1);
                if r.E < 0 then
                    Val_v := -Val_v;
                end if;
                Sat_v := false;
                Big_v := (others => '0');
                if Shift_v >= DW_c then
                    -- floor((v + 2^s) / 2^(s+1)) is zero once 2^s exceeds |v|
                    Big_v := (others => '0');
                elsif Shift_v >= 0 then
                    Big_v := resize(Val_v, Big_v'length) + shift_left(to_signed(1, Big_v'length), Shift_v);
                    Big_v := shift_right(Big_v, Shift_v + 1);
                elsif -Shift_v - 1 > WW_c + 1 then
                    -- floor((v 2^(-s) + 1) / 2) = v 2^(-s-1), beyond the weight range unless v = 0
                    Sat_v := Val_v /= 0;
                else
                    Big_v := shift_left(resize(Val_v, Big_v'length), -Shift_v - 1);
                end if;
                -- Saturation: an increment beyond the weight range is clipped with the weight anyway
                if (Sat_v and Val_v > 0) or Big_v > shift_left(to_signed(1, Big_v'length), WW_c) then
                    v.Inc := shift_left(to_signed(1, Inc_v'length), WW_c);
                elsif (Sat_v and Val_v < 0) or Big_v < -shift_left(to_signed(1, Big_v'length), WW_c) then
                    v.Inc := -shift_left(to_signed(1, Inc_v'length), WW_c);
                else
                    v.Inc := resize(Big_v, Inc_v'length);
                end if;
                v.IncIdx := r.J;
                v.IncVal := '1';
                if r.J = maximum(Cmax_c, 1) - 1 then
                    v.Fsm := UpdateLast_s;
                else
                    v.J := r.J + 1;
                end if;

            when UpdateLast_s =>
                v.IncVal := '0';
                v.Fsm    := Out_s;

            -- Output of the mapped quantizer index, write back of the state
            when Out_s =>
                if r.OutValid = '0' or Out_Ready = '1' then
                    v.OutValid := '1';
                    v.OutData  := std_logic_vector(resize(r.Delta, OutW_c));
                    v.OutKind  := ItemSample_c;
                    v.OutBand  := std_logic_vector(r.Z);
                    v.OutFirst := r.First;
                    v.OutInit  := r.Init;
                    v.OutLast  := r.LastSmp;
                    SrWrEna    <= '1';
                    DiffWrEna  <= toSl(P_c > 0);
                    WWrEna     <= toSl(Cmax_c > 0 and r.First = '0');
                    -- Next position in the input order (5.4.2)
                    if Bsq_c then
                        if XLast_v then
                            v.X := (others => '0');
                            if Yi_v = YSize_g - 1 then
                                v.Y       := (others => '0');
                                v.RowBase := (others => '0');
                                if ZLast_v then
                                    v.Z := (others => '0');
                                else
                                    v.Z := r.Z + 1;
                                end if;
                            else
                                v.Y       := r.Y + 1;
                                v.RowBase := r.RowBase + XSize_g;
                            end if;
                        else
                            v.X := r.X + 1;
                        end if;
                    else
                        if r.Z = r.SubLow + M_c - 1 or ZLast_v then
                            v.Z := r.SubLow;
                            if XLast_v then
                                v.X := (others => '0');
                                if ZLast_v then
                                    v.Z       := (others => '0');
                                    v.SubLow  := (others => '0');
                                    v.LimDone := '0';
                                    if Yi_v = YSize_g - 1 then
                                        v.Y       := (others => '0');
                                        v.RowBase := (others => '0');
                                    else
                                        v.Y       := r.Y + 1;
                                        v.RowBase := r.RowBase + XSize_g;
                                    end if;
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
                    v.Fsm := Idle_s;
                end if;

            -- Recovery
            when others =>
                v.Fsm := Idle_s;

        end case;

        -- Weight update stage 2 (4.10.3): weight plus increment, clipped to the weight range
        if r.IncVal = '1' then
            Wn_v            := resize(r.Wgt(r.IncIdx), Wn_v'length) + r.Inc;
            Wn_v            := clipSigned(Wn_v, -shift_left(to_signed(1, Wn_v'length), Om_c + 2),
                                          shift_left(to_signed(1, Wn_v'length), Om_c + 2) - 1);
            v.Wgt(r.IncIdx) := resize(Wn_v, WW_c);
        end if;

        -- Shifted local difference word: d_z enters, the oldest band leaves
        Word_v := (others => '0');
        if P_c > 0 then
            Word_v(DWs_c - 1 downto 0) := std_logic_vector(r.Dz(DWs_c - 1 downto 0));
            if P_c > 1 then
                Word_v(P_c * DWs_c - 1 downto DWs_c) := r.DiffWord((P_c - 1) * DWs_c - 1 downto 0);
            end if;
        end if;
        DiffWrData <= Word_v;

        for j in 0 to maximum(Cmax_c, 1) - 1 loop
            WWrData((j + 1) * WW_c - 1 downto j * WW_c) <= std_logic_vector(r.Wgt(j));
        end loop;

        r_next <= v;
    end process;

    -- Memory addresses that only depend on the position
    DiffRdAddr <= std_logic_vector(resize(r.X, DiffRdAddr'length)) when not Bsq_c else
                  std_logic_vector(resize(r.T, DiffRdAddr'length));
    WRdAddr    <= std_logic_vector(resize(r.Z, WRdAddr'length)) when not Bsq_c else
                  (others => '0');
    LimRdAddr  <= std_logic_vector(resize(r.Z, LimRdAddr'length));

    -- Outputs
    Out_Valid <= r.OutValid;
    Out_Data  <= r.OutData;
    Out_Kind  <= r.OutKind;
    Out_Band  <= r.OutBand;
    Out_First <= r.OutFirst;
    Out_Init  <= r.OutInit;
    Out_Last  <= r.OutLast;
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
                r.Fsm      <= Idle_s;
                r.X        <= (others => '0');
                r.Y        <= (others => '0');
                r.Z        <= (others => '0');
                r.SubLow   <= (others => '0');
                r.RowBase  <= (others => '0');
                r.LimDone  <= '0';
                r.OutValid <= '0';
                r.IncVal   <= '0';
                r.EccSec   <= '0';
                r.EccDed   <= '0';
                r.AbsConst <= (others => '0');
                r.RelConst <= (others => '0');
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Memories
    -----------------------------------------------------------------------------------------------
    i_sr_ram : entity olo.olo_ft_ram_sdp
        generic map (
            Depth_g    => SrDepth_c,
            Width_g    => D_c,
            RamStyle_g => RamStyle_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            Wr_Addr   => SrWrAddr,
            Wr_Ena    => SrWrEna,
            Wr_Data   => SrWrData,
            Rd_Addr   => SrRdAddr,
            Rd_Data   => SrRdData,
            Rd_Valid  => open,
            Rd_EccSec => EccSecVec(0),
            Rd_EccDed => EccDedVec(0)
        );

    g_diff : if P_c > 0 generate

        i_diff_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g    => DiffDepth_c,
                Width_g    => DiffBits_c,
                RamStyle_g => RamStyle_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                Wr_Addr   => DiffRdAddr,
                Wr_Ena    => DiffWrEna,
                Wr_Data   => DiffWrData,
                Rd_Addr   => DiffRdAddr,
                Rd_Data   => DiffRdData,
                Rd_Valid  => open,
                Rd_EccSec => EccSecVec(1),
                Rd_EccDed => EccDedVec(1)
            );

    else generate
        DiffRdData   <= (others => '0');
        EccSecVec(1) <= '0';
        EccDedVec(1) <= '0';
    end generate;

    g_weights : if Cmax_c > 0 generate

        i_weight_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g    => WDepth_c,
                Width_g    => WBits_c,
                RamStyle_g => RamStyle_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                Wr_Addr   => WRdAddr,
                Wr_Ena    => WWrEna,
                Wr_Data   => WWrData,
                Rd_Addr   => WRdAddr,
                Rd_Data   => WRdData,
                Rd_Valid  => open,
                Rd_EccSec => EccSecVec(2),
                Rd_EccDed => EccDedVec(2)
            );

    else generate
        WRdData      <= (others => '0');
        EccSecVec(2) <= '0';
        EccDedVec(2) <= '0';
    end generate;

    g_abs : if Periodic_c and UseAbs_c and AbsBandDependent_g generate

        i_abs_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g    => ZSize_g + 1,
                Width_g    => 16,
                RamStyle_g => RamStyle_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                Wr_Addr   => LimWrAddr,
                Wr_Ena    => AbsWrEna,
                Wr_Data   => Lim_Data,
                Rd_Addr   => LimRdAddr,
                Rd_Data   => AbsRdData,
                Rd_Valid  => open,
                Rd_EccSec => EccSecVec(3),
                Rd_EccDed => EccDedVec(3)
            );

    else generate
        AbsRdData    <= (others => '0');
        EccSecVec(3) <= '0';
        EccDedVec(3) <= '0';
    end generate;

    g_rel : if Periodic_c and UseRel_c and RelBandDependent_g generate

        i_rel_ram : entity olo.olo_ft_ram_sdp
            generic map (
                Depth_g    => ZSize_g + 1,
                Width_g    => 16,
                RamStyle_g => RamStyle_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                Wr_Addr   => LimWrAddr,
                Wr_Ena    => RelWrEna,
                Wr_Data   => Lim_Data,
                Rd_Addr   => LimRdAddr,
                Rd_Data   => RelRdData,
                Rd_Valid  => open,
                Rd_EccSec => EccSecVec(4),
                Rd_EccDed => EccDedVec(4)
            );

    else generate
        RelRdData    <= (others => '0');
        EccSecVec(4) <= '0';
        EccDedVec(4) <= '0';
    end generate;

end architecture;
