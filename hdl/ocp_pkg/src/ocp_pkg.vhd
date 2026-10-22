---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Definitions shared by all OpenCompact modules: the codeword and entropy coder input streams,
-- the decoding of the string generics and the access to the per-band parameter tables
-- (CCSDS 123.0-B-2).
--
-- Documentation: hdl/ocp_pkg/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocp_pkg is

    -- Codeword stream (entropy coders and header to the bit packer): the Length least significant
    -- bits of Data are appended to the compressed image, most significant bit first
    constant CwWidth_c    : positive := 96;
    constant CwLenWidth_c : positive := 7;

    -- Entropy coder input sequence (CCSDS 5.4.1): mapped quantizer index or error limit value
    constant ItemSample_c   : std_logic_vector(1 downto 0) := "00";
    constant ItemAbsLimit_c : std_logic_vector(1 downto 0) := "01";
    constant ItemRelLimit_c : std_logic_vector(1 downto 0) := "10";

    -- Codes of the string generics (values of the header fields, CCSDS 5.3)
    constant OrderBi_c  : natural := 0;
    constant OrderBsq_c : natural := 1;

    constant CoderSample_c : natural := 0;
    constant CoderHybrid_c : natural := 1;
    constant CoderBlock_c  : natural := 2;

    constant FidLossless_c : natural := 0;
    constant FidAbsolute_c : natural := 1;
    constant FidRelative_c : natural := 2;
    constant FidBoth_c     : natural := 3;

    constant SumWideNeighbor_c   : natural := 0;
    constant SumNarrowNeighbor_c : natural := 1;
    constant SumWideColumn_c     : natural := 2;
    constant SumNarrowColumn_c   : natural := 3;

    -- Decoding of the string generics; an unknown value stops the elaboration
    function encodingOrderCode (s : string) return natural;
    function entropyCoderCode (s : string) return natural;
    function fidelityCode (s : string) return natural;
    function localSumCode (s : string) return natural;
    function fullPrediction (s : string) return boolean;

    -- Element i of a per-band parameter table; the last element repeats for higher indexes
    function vecElem (v : integer_vector; i : natural) return integer;

    -- Number of inter-band local differences used in band z: Pz* = min(z, P) (CCSDS 4.2)
    function bandsUsed (z : natural; p : natural) return natural;

    -- Number of local differences Cz used in band z (CCSDS 4.3.2)
    function diffsUsed (z : natural; p : natural; full : boolean) return natural;

    -- Number of entries of a per-band table with Pz* + extra entries per band (weight tables, CCSDS 5.3.3.3)
    function bandTableSize (nz : natural; p : natural; extra : natural) return natural;

    -- Index of the first entry of band z in such a table
    function bandTableStart (z : natural; p : natural; extra : natural) return natural;

    -- Conversions
    function toSl (b : boolean) return std_logic;
    function toInt (b : boolean) return natural;

    -- Bit flip pattern of the error injection into a SECDED codeword of the given width: bit 0
    -- (corrected single error) or bits 0 and 1 (detected double error)
    function injPattern (width : positive; double : std_logic) return std_logic_vector;

    -- Issue conditions of the predictor that depend on the image dimensions (ocp_predictor architecture): the
    -- sub-frame interleaving depth M; consecutive samples of a band follow each other directly (BSQ, M = 1), also
    -- from one row to the next (BSQ, NZ = 1); the issue distance between samples of the same band without the
    -- weights and between a sample and the sample of the previous band at the same pixel
    type IssueDist_r is record
        M       : positive;
        Gap1    : boolean;
        RunRows : boolean;
        LFix    : natural;
        LCross  : natural;
    end record;

    -- The distances lWin (window of the previous line), lRep (sample representatives) and lDw (central local
    -- differences) are the latencies of the predictor pipeline; the image dimensions decide which of them apply
    function issueDist (
        bsq : boolean;
        sfd : positive;
        nx : positive;
        ny : positive;
        nz : positive;
        predBands : natural;
        repIsSample : boolean;
        wUsed : boolean;
        crossRep : boolean;
        lWin : natural;
        lRep : natural;
        lDw : natural) return IssueDist_r;

    -- Image-start sequencer of the predictor (ocp_image_start): width SatW of the saturated factors (2^SatW exceeds
    -- the latencies lRep and lDw) and number of clock cycles from Start to Done (SatW + 3)
    function imageStartSatWidth (lRep : natural; lDw : natural) return positive;
    function imageStartCycles (lRep : natural; lDw : natural) return positive;

    -- Low-entropy codes of the hybrid entropy coder: input symbol limits and thresholds (CCSDS table 5-16)
    type LeNatArray_t is array (0 to 15) of natural;

    constant LeLimit_c     : LeNatArray_t := (12, 10, 8, 6, 6, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 0);
    constant LeThreshold_c : LeNatArray_t := (303336, 225404, 166979, 128672, 95597, 69670, 50678, 34898,
                                              23331, 14935, 9282, 5510, 3195, 1928, 1112, 408);

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocp_pkg is

    function encodingOrderCode (s : string) return natural is
    begin
        if s = "BI" then
            return OrderBi_c;
        elsif s = "BSQ" then
            return OrderBsq_c;
        end if;
        report "ocp_pkg: EncodingOrder_g must be BI or BSQ" severity failure;
        return OrderBi_c;
    end function;

    function entropyCoderCode (s : string) return natural is
    begin
        if s = "SAMPLE_ADAPTIVE" then
            return CoderSample_c;
        elsif s = "HYBRID" then
            return CoderHybrid_c;
        elsif s = "BLOCK_ADAPTIVE" then
            return CoderBlock_c;
        end if;
        report "ocp_pkg: EntropyCoder_g must be SAMPLE_ADAPTIVE, HYBRID or BLOCK_ADAPTIVE" severity failure;
        return CoderSample_c;
    end function;

    function fidelityCode (s : string) return natural is
    begin
        if s = "LOSSLESS" then
            return FidLossless_c;
        elsif s = "ABSOLUTE" then
            return FidAbsolute_c;
        elsif s = "RELATIVE" then
            return FidRelative_c;
        elsif s = "ABSOLUTE_RELATIVE" then
            return FidBoth_c;
        end if;
        report "ocp_pkg: Fidelity_g must be LOSSLESS, ABSOLUTE, RELATIVE or ABSOLUTE_RELATIVE" severity failure;
        return FidLossless_c;
    end function;

    function localSumCode (s : string) return natural is
    begin
        if s = "WIDE_NEIGHBOR" then
            return SumWideNeighbor_c;
        elsif s = "NARROW_NEIGHBOR" then
            return SumNarrowNeighbor_c;
        elsif s = "WIDE_COLUMN" then
            return SumWideColumn_c;
        elsif s = "NARROW_COLUMN" then
            return SumNarrowColumn_c;
        end if;
        report "ocp_pkg: LocalSum_g must be WIDE_NEIGHBOR, NARROW_NEIGHBOR, WIDE_COLUMN or NARROW_COLUMN"
            severity failure;
        return SumWideNeighbor_c;
    end function;

    function fullPrediction (s : string) return boolean is
    begin
        if s = "FULL" then
            return true;
        elsif s = "REDUCED" then
            return false;
        end if;
        report "ocp_pkg: PredictionMode_g must be FULL or REDUCED" severity failure;
        return true;
    end function;

    function vecElem (v : integer_vector; i : natural) return integer is
    begin
        if i < v'length then
            return v(v'low + i);
        end if;
        return v(v'high);
    end function;

    function bandsUsed (z : natural; p : natural) return natural is
    begin
        return minimum(z, p);
    end function;

    function diffsUsed (z : natural; p : natural; full : boolean) return natural is
    begin
        if full then
            return minimum(z, p) + 3;
        end if;
        return minimum(z, p);
    end function;

    function bandTableSize (nz : natural; p : natural; extra : natural) return natural is
    begin
        return bandTableStart(nz, p, extra);
    end function;

    function bandTableStart (z : natural; p : natural; extra : natural) return natural is
        variable Start_v : natural := 0;
    begin
        -- Bands z < P have z inter-band entries, all later bands P
        if z <= p then
            Start_v := z * extra + (z * (z - 1)) / 2;
        else
            Start_v := p * extra + (p * (p - 1)) / 2 + (z - p) * (p + extra);
        end if;
        return Start_v;
    end function;

    function toSl (b : boolean) return std_logic is
    begin
        if b then
            return '1';
        end if;
        return '0';
    end function;

    function toInt (b : boolean) return natural is
    begin
        if b then
            return 1;
        end if;
        return 0;
    end function;

    function injPattern (width : positive; double : std_logic) return std_logic_vector is
        variable P_v : std_logic_vector(width - 1 downto 0) := (others => '0');
    begin
        P_v(0) := '1';
        if double = '1' and width > 1 then
            P_v(1) := '1';
        end if;
        return P_v;
    end function;

    function issueDist (
        bsq : boolean;
        sfd : positive;
        nx : positive;
        ny : positive;
        nz : positive;
        predBands : natural;
        repIsSample : boolean;
        wUsed : boolean;
        crossRep : boolean;
        lWin : natural;
        lRep : natural;
        lDw : natural) return IssueDist_r is
        -- The gaps are only compared with the latencies: factors above Cap_c give the same results and keep the
        -- products within the integer range
        constant Cap_c     : positive := 4096;
        variable R_v       : IssueDist_r;
        variable RowGap_v  : natural;
        variable DiffGap_v : natural;
        variable SameRep_v : boolean;
        variable CrossDw_v : boolean;
    begin
        R_v.M       := minimum(sfd, nz);
        R_v.Gap1    := bsq or R_v.M = 1;
        R_v.RunRows := bsq or nz = 1;
        -- Issues between a sample and the sample of the previous row of its band (window, sample
        -- representatives), and between the central local differences of a pixel written in one band and read in
        -- the next (BSQ: the next band, BI: the first band of the next sub-frame)
        if bsq then
            RowGap_v  := minimum(nx - 1, Cap_c);
            DiffGap_v := minimum(nx, Cap_c) * minimum(ny, Cap_c);
        else
            RowGap_v  := minimum(nx - 1, Cap_c) * minimum(R_v.M, Cap_c);
            DiffGap_v := RowGap_v + 1;
        end if;
        SameRep_v  := not repIsSample and (wUsed or RowGap_v < lRep);
        CrossDw_v  := predBands > 0 and (bsq or R_v.M < nz) and DiffGap_v < lDw;
        R_v.LFix   := 0;
        R_v.LCross := 0;
        if not R_v.Gap1 then
            R_v.LFix := lWin;
        end if;
        if SameRep_v then
            R_v.LFix := maximum(R_v.LFix, lRep);
        end if;
        if crossRep then
            R_v.LCross := lRep;
        end if;
        if CrossDw_v then
            R_v.LCross := maximum(R_v.LCross, lDw);
        end if;
        return R_v;
    end function;

    function imageStartSatWidth (lRep : natural; lDw : natural) return positive is
        variable W_v : positive := 1;
    begin

        while 2 ** W_v <= maximum(lRep, lDw) loop
            W_v := W_v + 1;
        end loop;

        return W_v;
    end function;

    function imageStartCycles (lRep : natural; lDw : natural) return positive is
    begin
        -- Start (factors), one step per bit of the factor B (SatW + 1), comparisons
        return imageStartSatWidth(lRep, lDw) + 3;
    end function;

end package body;
