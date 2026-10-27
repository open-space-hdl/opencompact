---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Header of the compressed image (CCSDS 123.0-B-2 5.3): image metadata, predictor metadata and
-- entropy coder metadata. The header is computed from the generics during elaboration and sent in
-- parts of up to 64 bits after each Start pulse.
--
-- Documentation: hdl/ocp_core/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocp_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_header is
    generic (
        -- Image
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
        WeightExpOffsetTable_g : boolean                   := false;
        WeightExpOffsets_g     : integer_vector            := (0 => 0);
        CustomWeights_g        : boolean                   := false;
        WeightInitTable_g      : boolean                   := false;
        WeightInitResolution_g : natural range 0 to 22     := 0;
        WeightInitValues_g     : integer_vector            := (0 => 0);
        -- Quantizer
        Fidelity_g             : string                    := "LOSSLESS";
        PeriodicUpdate_g       : boolean                   := false;
        UpdatePeriodExp_g      : natural range 0 to 9      := 0;
        AbsBandDependent_g     : boolean                   := false;
        AbsBitDepth_g          : positive range 1 to 16    := 1;
        AbsErrorLimits_g       : integer_vector            := (0 => 0);
        RelBandDependent_g     : boolean                   := false;
        RelBitDepth_g          : positive range 1 to 16    := 1;
        RelErrorLimits_g       : integer_vector            := (0 => 0);
        -- Sample representatives
        SampleRepResolution_g  : natural range 0 to 4      := 0;
        DampingBandVarying_g   : boolean                   := false;
        DampingTable_g         : boolean                   := false;
        Damping_g              : integer_vector            := (0 => 0);
        OffsetBandVarying_g    : boolean                   := false;
        OffsetTable_g          : boolean                   := false;
        Offset_g               : integer_vector            := (0 => 0);
        -- Sample-adaptive and hybrid entropy coder
        UnaryLimit_g           : positive range 8 to 32    := 16;
        RescaleCounterSize_g   : positive range 4 to 11    := 6;
        InitialCountExp_g      : positive range 1 to 8     := 1;
        AccuInitBandVarying_g  : boolean                   := false;
        AccuInitTable_g        : boolean                   := false;
        AccuInit_g             : integer_vector            := (0 => 3);
        -- Block-adaptive entropy coder
        BlockSize_g            : positive                  := 16;
        RestrictedCodes_g      : boolean                   := false;
        RefInterval_g          : positive range 1 to 4096  := 4096;
        -- Runtime configuration: X, Y and Z Size, the sub-frame interleaving depth and the
        -- band-independent error limit values of every image from the configuration inputs
        RuntimeConfig_g        : boolean                   := false;
        -- Runtime parameters (with RuntimeConfig_g): the user-defined data, the sub-frame interleaving
        -- depth, the weight update parameters and the entropy coder parameters from the configuration inputs
        RuntimeParams_g        : boolean                   := false
    );
    port (
        Clk                : in    std_logic;
        Rst                : in    std_logic;
        Start              : in    std_logic;
        Out_Valid          : out   std_logic;
        Out_Ready          : in    std_logic;
        -- Parts of the header: the Out_Length least significant bits of Out_Data, first bit in the
        -- most significant of them
        Out_Data           : out   std_logic_vector(63 downto 0);
        Out_Length         : out   std_logic_vector(CwLenWidth_c - 1 downto 0);
        Out_Last           : out   std_logic;
        -- Runtime configuration: NX, NY, NZ and the error limit values of the image whose header is
        -- output (stable from Start to the last part)
        Cfg_XSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_YSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_ZSize          : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_AbsLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        Cfg_RelLimit       : in    std_logic_vector(15 downto 0) := (others => '0');
        -- Runtime parameters: the bits of their header fields for the image whose header is output (stable
        -- from Start to the last part): user-defined data, M mod 2^16, log2 t_inc - 4, vmin + 6, vmax + 6,
        -- Umax mod 32, gamma* - 4, gamma0 mod 8, K, r mod 4096
        Cfg_UserData       : in    std_logic_vector(7 downto 0)  := (others => '0');
        Cfg_M              : in    std_logic_vector(15 downto 0) := (others => '0');
        Cfg_WeightInterval : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_WeightVmin     : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_WeightVmax     : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_UnaryLimit     : in    std_logic_vector(4 downto 0)  := (others => '0');
        Cfg_RescaleSize    : in    std_logic_vector(2 downto 0)  := (others => '0');
        Cfg_InitCountExp   : in    std_logic_vector(2 downto 0)  := (others => '0');
        Cfg_AccuInit       : in    std_logic_vector(3 downto 0)  := (others => '0');
        Cfg_RefInterval    : in    std_logic_vector(11 downto 0) := (others => '0')
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_header is

    constant Order_c    : natural := encodingOrderCode(EncodingOrder_g);
    constant Coder_c    : natural := entropyCoderCode(EntropyCoder_g);
    constant Fid_c      : natural := fidelityCode(Fidelity_g);
    constant Sum_c      : natural := localSumCode(LocalSum_g);
    constant Full_c     : boolean := fullPrediction(PredictionMode_g);
    constant UseAbs_c   : boolean := Fid_c = FidAbsolute_c or Fid_c = FidBoth_c;
    constant UseRel_c   : boolean := Fid_c = FidRelative_c or Fid_c = FidBoth_c;
    constant Periodic_c : boolean := PeriodicUpdate_g and Fid_c /= FidLossless_c;
    constant Theta_c    : natural := SampleRepResolution_g;

    -- Upper bound of the header length in bits
    constant MaxBits_c : positive := 96 + SupTableData_g'length + 40 + ZSize_g * 18 * 22 + 8 + ZSize_g * 16 * 4 + 8 +
                                     8 + 2 * (8 + ZSize_g * 16 + 8) + 24 + 2 * (ZSize_g * 4 + 8) + 16 + ZSize_g * 4 + 8;

    subtype Buf_t is std_logic_vector(0 to MaxBits_c - 1);

    -- Appends the width least significant bits of value (two's complement) at position pos
    procedure put (
        buf   : inout Buf_t;
        pos   : inout natural;
        value : in    integer;
        width : in    natural) is
        variable Bits_v : std_logic_vector(31 downto 0);
    begin
        Bits_v := std_logic_vector(to_signed(value, 32));

        for i in width - 1 downto 0 loop
            buf(pos) := Bits_v(i);
            pos      := pos + 1;
        end loop;

    end procedure;

    -- Fill bits up to the next byte boundary (CCSDS 5.3.1.2)
    procedure align (
        buf : inout Buf_t;
        pos : inout natural) is
    begin

        while pos mod 8 /= 0 loop
            buf(pos) := '0';
            pos      := pos + 1;
        end loop;

    end procedure;

    -- Bit positions of the header fields of the runtime configuration (X, Y, Z Size: bits 8, 24, 40) and of
    -- the runtime parameters (user-defined data: bit 0)
    type FieldPos_r is record
        M      : natural;
        AbsLim : natural;
        RelLim : natural;
        TInc   : natural;
        Vmin   : natural;
        Vmax   : natural;
        Umax   : natural;
        GStar  : natural;
        G0     : natural;
        K      : natural;
        R      : natural;
    end record;

    procedure build (
        buf : inout Buf_t;
        pos : inout natural;
        fld : inout FieldPos_r) is
        variable Idx_v : natural;
        variable Pz_v  : natural;
    begin
        buf := (others => '0');
        pos := 0;
        fld := (others => 0);
        -- Image metadata, essential subpart (CCSDS table 5-3)
        put(buf, pos, UserData_g, 8);
        put(buf, pos, XSize_g mod 65536, 16);
        put(buf, pos, YSize_g mod 65536, 16);
        put(buf, pos, ZSize_g mod 65536, 16);
        put(buf, pos, toInt(SignedSamples_g), 1);
        put(buf, pos, 0, 1);
        put(buf, pos, toInt(DynamicRange_g > 16), 1);
        put(buf, pos, DynamicRange_g mod 16, 4);
        put(buf, pos, Order_c, 1);
        fld.M := pos;
        if Order_c = OrderBi_c then
            put(buf, pos, SubFrameDepth_g mod 65536, 16);
        else
            put(buf, pos, 0, 16);
        end if;
        put(buf, pos, 0, 2);
        put(buf, pos, OutputWordSize_g mod 8, 3);
        put(buf, pos, Coder_c, 2);
        put(buf, pos, 0, 1);
        put(buf, pos, Fid_c, 2);
        put(buf, pos, 0, 2);
        put(buf, pos, SupTableCount_g, 4);
        -- Supplementary information tables (CCSDS 5.3.2.3), encoded by the user
        if SupTableCount_g > 0 then

            for i in SupTableData_g'range loop
                buf(pos) := SupTableData_g(i);
                pos      := pos + 1;
            end loop;

        end if;
        -- Predictor metadata, primary subpart (CCSDS table 5-6)
        put(buf, pos, 0, 1);
        put(buf, pos, toInt(Theta_c > 0), 1);
        put(buf, pos, PredictionBands_g, 4);
        put(buf, pos, toInt(not Full_c), 1);
        put(buf, pos, toInt(WeightExpOffsetsUsed_g), 1);
        put(buf, pos, Sum_c, 2);
        put(buf, pos, RegisterSize_g mod 64, 6);
        put(buf, pos, WeightResolution_g - 4, 4);
        fld.TInc := pos;
        put(buf, pos, WeightUpdateInterval_g - 4, 4);
        fld.Vmin := pos;
        put(buf, pos, WeightUpdateVmin_g + 6, 4);
        fld.Vmax := pos;
        put(buf, pos, WeightUpdateVmax_g + 6, 4);
        put(buf, pos, toInt(WeightExpOffsetsUsed_g and WeightExpOffsetTable_g), 1);
        put(buf, pos, toInt(CustomWeights_g), 1);
        put(buf, pos, toInt(CustomWeights_g and WeightInitTable_g), 1);
        if CustomWeights_g then
            put(buf, pos, WeightInitResolution_g, 5);
        else
            put(buf, pos, 0, 5);
        end if;
        -- Weight initialization table (CCSDS 5.3.3.3.2)
        if CustomWeights_g and WeightInitTable_g then
            Idx_v := 0;

            for z in 0 to ZSize_g - 1 loop

                for j in 0 to diffsUsed(z, PredictionBands_g, Full_c) - 1 loop
                    put(buf, pos, vecElem(WeightInitValues_g, Idx_v), WeightInitResolution_g);
                    Idx_v := Idx_v + 1;
                end loop;

            end loop;

            align(buf, pos);
        end if;
        -- Weight exponent offset table (CCSDS 5.3.3.3.3)
        if WeightExpOffsetsUsed_g and WeightExpOffsetTable_g then
            Idx_v := 0;

            for z in 0 to ZSize_g - 1 loop
                Pz_v := bandsUsed(z, PredictionBands_g);

                for j in 0 to Pz_v - 1 + toInt(Full_c) loop
                    put(buf, pos, vecElem(WeightExpOffsets_g, Idx_v), 4);
                    Idx_v := Idx_v + 1;
                end loop;

            end loop;

            align(buf, pos);
        end if;
        -- Quantization subpart (CCSDS 5.3.3.4)
        if Fid_c /= FidLossless_c then
            if Order_c = OrderBi_c then
                put(buf, pos, 0, 1);
                put(buf, pos, toInt(Periodic_c), 1);
                put(buf, pos, 0, 2);
                if Periodic_c then
                    put(buf, pos, UpdatePeriodExp_g, 4);
                else
                    put(buf, pos, 0, 4);
                end if;
            end if;
            if UseAbs_c then
                put(buf, pos, 0, 1);
                put(buf, pos, toInt(AbsBandDependent_g), 1);
                put(buf, pos, 0, 2);
                put(buf, pos, AbsBitDepth_g mod 16, 4);
                if not Periodic_c then
                    if AbsBandDependent_g then

                        for z in 0 to ZSize_g - 1 loop
                            put(buf, pos, vecElem(AbsErrorLimits_g, z), AbsBitDepth_g);
                        end loop;

                    else
                        fld.AbsLim := pos;
                        put(buf, pos, vecElem(AbsErrorLimits_g, 0), AbsBitDepth_g);
                    end if;
                    align(buf, pos);
                end if;
            end if;
            if UseRel_c then
                put(buf, pos, 0, 1);
                put(buf, pos, toInt(RelBandDependent_g), 1);
                put(buf, pos, 0, 2);
                put(buf, pos, RelBitDepth_g mod 16, 4);
                if not Periodic_c then
                    if RelBandDependent_g then

                        for z in 0 to ZSize_g - 1 loop
                            put(buf, pos, vecElem(RelErrorLimits_g, z), RelBitDepth_g);
                        end loop;

                    else
                        fld.RelLim := pos;
                        put(buf, pos, vecElem(RelErrorLimits_g, 0), RelBitDepth_g);
                    end if;
                    align(buf, pos);
                end if;
            end if;
        end if;
        -- Sample representative subpart (CCSDS 5.3.3.5)
        if Theta_c > 0 then
            put(buf, pos, 0, 5);
            put(buf, pos, Theta_c, 3);
            put(buf, pos, 0, 1);
            put(buf, pos, toInt(DampingBandVarying_g), 1);
            put(buf, pos, toInt(DampingBandVarying_g and DampingTable_g), 1);
            put(buf, pos, 0, 1);
            if DampingBandVarying_g then
                put(buf, pos, 0, 4);
            else
                put(buf, pos, vecElem(Damping_g, 0), 4);
            end if;
            put(buf, pos, 0, 1);
            put(buf, pos, toInt(OffsetBandVarying_g), 1);
            put(buf, pos, toInt(OffsetBandVarying_g and OffsetTable_g), 1);
            put(buf, pos, 0, 1);
            if OffsetBandVarying_g then
                put(buf, pos, 0, 4);
            else
                put(buf, pos, vecElem(Offset_g, 0), 4);
            end if;
            if DampingBandVarying_g and DampingTable_g then

                for z in 0 to ZSize_g - 1 loop
                    put(buf, pos, vecElem(Damping_g, z), Theta_c);
                end loop;

                align(buf, pos);
            end if;
            if OffsetBandVarying_g and OffsetTable_g then

                for z in 0 to ZSize_g - 1 loop
                    put(buf, pos, vecElem(Offset_g, z), Theta_c);
                end loop;

                align(buf, pos);
            end if;
        end if;
        -- Entropy coder metadata (CCSDS 5.3.4)
        if Coder_c = CoderSample_c or Coder_c = CoderHybrid_c then
            fld.Umax  := pos;
            put(buf, pos, UnaryLimit_g mod 32, 5);
            fld.GStar := pos;
            put(buf, pos, RescaleCounterSize_g - 4, 3);
            fld.G0    := pos;
            put(buf, pos, InitialCountExp_g mod 8, 3);
        end if;
        if Coder_c = CoderSample_c then
            fld.K := pos;
            if AccuInitBandVarying_g then
                put(buf, pos, 15, 4);
            else
                put(buf, pos, vecElem(AccuInit_g, 0), 4);
            end if;
            put(buf, pos, toInt(AccuInitBandVarying_g and AccuInitTable_g), 1);
            if AccuInitBandVarying_g and AccuInitTable_g then

                for z in 0 to ZSize_g - 1 loop
                    put(buf, pos, vecElem(AccuInit_g, z), 4);
                end loop;

                align(buf, pos);
            end if;
        elsif Coder_c = CoderHybrid_c then
            put(buf, pos, 0, 5);
        else
            put(buf, pos, 0, 1);

            case BlockSize_g is
                when 8 => put(buf, pos, 0, 2);
                when 16 => put(buf, pos, 1, 2);
                when 32 => put(buf, pos, 2, 2);
                when others => put(buf, pos, 3, 2);
            end case;

            put(buf, pos, toInt(RestrictedCodes_g), 1);
            fld.R := pos;
            put(buf, pos, RefInterval_g mod 4096, 12);
        end if;
    end procedure;

    function headerBits return Buf_t is
        variable Buf_v : Buf_t;
        variable Pos_v : natural;
        variable Fld_v : FieldPos_r;
    begin
        build(Buf_v, Pos_v, Fld_v);
        return Buf_v;
    end function;

    function headerBytes return positive is
        variable Buf_v : Buf_t;
        variable Pos_v : natural;
        variable Fld_v : FieldPos_r;
    begin
        build(Buf_v, Pos_v, Fld_v);
        return Pos_v / 8;
    end function;

    function fieldPos return FieldPos_r is
        variable Buf_v : Buf_t;
        variable Pos_v : natural;
        variable Fld_v : FieldPos_r;
    begin
        build(Buf_v, Pos_v, Fld_v);
        return Fld_v;
    end function;

    constant Header_c      : Buf_t    := headerBits;
    constant HeaderBytes_c : positive := headerBytes;
    constant Parts_c       : positive := (HeaderBytes_c + 7) / 8;

    -- Parts of 64 bits, the last one shorter
    type PartArr_t is array (0 to Parts_c - 1) of std_logic_vector(63 downto 0);

    function parts return PartArr_t is
        variable P_v   : PartArr_t := (others => (others => '0'));
        variable Len_v : natural;
    begin

        for i in 0 to Parts_c - 1 loop
            Len_v := minimum(64, 8 * HeaderBytes_c - 64 * i);

            for m in 0 to Len_v - 1 loop
                P_v(i)(Len_v - 1 - m) := Header_c(64 * i + m);
            end loop;

        end loop;

        return P_v;
    end function;

    constant PartRom_c : PartArr_t := parts;
    constant LastLen_c : positive  := 8 * HeaderBytes_c - 64 * (Parts_c - 1);

    -- Runtime configuration: the header bits of the runtime fields replace the bits of the ROM part that holds
    -- them (CO-HD-08); the fields have fixed positions and widths, so the length of the header is constant
    constant Fld_c : FieldPos_r := fieldPos;

    -- Places the width least significant bits of value at header bit pos into part index (most significant
    -- bit first, as the procedure put)
    procedure place (
        part  : inout std_logic_vector(63 downto 0);
        index : in    natural;
        pos   : in    natural;
        width : in    natural;
        value : in    unsigned) is
        variable P_v   : natural;
        variable Len_v : natural;
    begin

        for b in 0 to width - 1 loop
            P_v := pos + b;
            if P_v / 64 = index then
                Len_v                          := minimum(64, 8 * HeaderBytes_c - 64 * index);
                part(Len_v - 1 - (P_v mod 64)) := value(width - 1 - b);
            end if;
        end loop;

    end procedure;

    -- Part index of the header with the fields of the image
    function runtimePart (
        index : natural;
        nx    : unsigned(16 downto 0);
        ny    : unsigned(16 downto 0);
        nz    : unsigned(16 downto 0);
        a     : unsigned(15 downto 0);
        r     : unsigned(15 downto 0)) return std_logic_vector is
        variable P_v : std_logic_vector(63 downto 0);
        variable M_v : unsigned(16 downto 0);
    begin
        P_v := PartRom_c(index);
        -- X, Y and Z Size: the dimensions modulo 2^16 (CCSDS 5.3.2.2)
        place(P_v, index, 8, 16, nx(15 downto 0));
        place(P_v, index, 24, 16, ny(15 downto 0));
        place(P_v, index, 40, 16, nz(15 downto 0));
        -- Sub-frame interleaving depth min(M, NZ) in BI order (a runtime parameter: placed by paramPart)
        if Order_c = OrderBi_c and not RuntimeParams_g then
            M_v := to_unsigned(SubFrameDepth_g, 17);
            if nz < SubFrameDepth_g then
                M_v := nz;
            end if;
            place(P_v, index, Fld_c.M, 16, M_v(15 downto 0));
        end if;
        -- Band-independent absolute and relative error limit values (CCSDS 5.3.3.4)
        if UseAbs_c then
            place(P_v, index, Fld_c.AbsLim, AbsBitDepth_g, a(AbsBitDepth_g - 1 downto 0));
        end if;
        if UseRel_c then
            place(P_v, index, Fld_c.RelLim, RelBitDepth_g, r(RelBitDepth_g - 1 downto 0));
        end if;
        return P_v;
    end function;

    -- Part index with the header fields of the runtime parameters of the image (CCSDS 5.3.2.2, 5.3.3.2, 5.3.4)
    procedure paramPart (
        part  : inout std_logic_vector(63 downto 0);
        index : in    natural;
        user  : in    std_logic_vector(7 downto 0);
        m     : in    std_logic_vector(15 downto 0);
        tinc  : in    std_logic_vector(3 downto 0);
        vmin  : in    std_logic_vector(3 downto 0);
        vmax  : in    std_logic_vector(3 downto 0);
        umax  : in    std_logic_vector(4 downto 0);
        gstar : in    std_logic_vector(2 downto 0);
        g0    : in    std_logic_vector(2 downto 0);
        k     : in    std_logic_vector(3 downto 0);
        ref   : in    std_logic_vector(11 downto 0)) is
    begin
        place(part, index, 0, 8, unsigned(user));
        if Order_c = OrderBi_c then
            place(part, index, Fld_c.M, 16, unsigned(m));
        end if;
        place(part, index, Fld_c.TInc, 4, unsigned(tinc));
        place(part, index, Fld_c.Vmin, 4, unsigned(vmin));
        place(part, index, Fld_c.Vmax, 4, unsigned(vmax));
        if Coder_c = CoderSample_c or Coder_c = CoderHybrid_c then
            place(part, index, Fld_c.Umax, 5, unsigned(umax));
            place(part, index, Fld_c.GStar, 3, unsigned(gstar));
            place(part, index, Fld_c.G0, 3, unsigned(g0));
        end if;
        -- K: the accumulator initialisation constant (with band-varying values the constant field 15)
        if Coder_c = CoderSample_c and not AccuInitBandVarying_g then
            place(part, index, Fld_c.K, 4, unsigned(k));
        end if;
        if Coder_c = CoderBlock_c then
            place(part, index, Fld_c.R, 12, unsigned(ref));
        end if;
    end procedure;

    type TwoProcess_r is record
        Active : std_logic;
        Index  : natural range 0 to Parts_c - 1;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v : TwoProcess_r;
    begin
        v := r;
        if r.Active = '0' then
            if Start = '1' then
                v.Active := '1';
                v.Index  := 0;
            end if;
        elsif Out_Ready = '1' then
            if r.Index = Parts_c - 1 then
                v.Active := '0';
            else
                v.Index := r.Index + 1;
            end if;
        end if;
        r_next <= v;
    end process;

    Out_Valid <= r.Active;

    g_const : if not RuntimeConfig_g generate
        Out_Data <= PartRom_c(r.Index);
    end generate;

    g_runtime : if RuntimeConfig_g and not RuntimeParams_g generate
        Out_Data <= runtimePart(r.Index, unsigned(Cfg_XSize), unsigned(Cfg_YSize), unsigned(Cfg_ZSize),
                                unsigned(Cfg_AbsLimit), unsigned(Cfg_RelLimit));
    end generate;

    g_params : if RuntimeParams_g generate

        p_part : process (all) is
            variable P_v : std_logic_vector(63 downto 0);
        begin
            P_v      := runtimePart(r.Index, unsigned(Cfg_XSize), unsigned(Cfg_YSize), unsigned(Cfg_ZSize),
                                    unsigned(Cfg_AbsLimit), unsigned(Cfg_RelLimit));
            paramPart(P_v, r.Index, Cfg_UserData, Cfg_M, Cfg_WeightInterval, Cfg_WeightVmin, Cfg_WeightVmax,
                      Cfg_UnaryLimit, Cfg_RescaleSize, Cfg_InitCountExp, Cfg_AccuInit, Cfg_RefInterval);
            Out_Data <= P_v;
        end process;

    end generate;

    Out_Length <= std_logic_vector(to_unsigned(LastLen_c, CwLenWidth_c)) when r.Index = Parts_c - 1 else
                  std_logic_vector(to_unsigned(64, CwLenWidth_c));
    Out_Last   <= toSl(r.Index = Parts_c - 1);

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Active <= '0';
                r.Index  <= 0;
            end if;
        end if;
    end process;

end architecture;
