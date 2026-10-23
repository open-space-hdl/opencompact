---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Image-start sequencer of the predictor with runtime image dimensions: computes from NX, NY and NZ
-- of an image the issue conditions that the elaboration computes for constant dimensions (function
-- issueDist of ocp_pkg). The gaps between dependent samples are products of the dimensions, but they
-- are only compared with the pipeline latencies; the factors are saturated just above the largest
-- latency and multiplied by one adder in a fixed number of steps. Done follows Start after
-- imageStartCycles(...) clock cycles for every input.
--
-- Documentation: hdl/ocp_predictor/docs/architecture.md

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
entity ocp_image_start is
    generic (
        -- Encoding order and sub-frame interleaving depth of the configuration
        Bsq_g           : boolean                   := false;
        SubFrameDepth_g : positive range 1 to 65536 := 4;
        -- Predictor: number of prediction bands, sample representatives equal to the samples, the
        -- previous sample of the band enters the local sum or the directional differences, the
        -- sample representatives of the previous band are used
        PredBands_g     : natural range 0 to 15     := 3;
        RepIsSample_g   : boolean                   := true;
        WUsed_g         : boolean                   := true;
        CrossRep_g      : boolean                   := false;
        -- Latencies (issue distances) of the window, the sample representatives and the central
        -- local differences
        LWin_g          : natural                   := 4;
        LRep_g          : natural                   := 20;
        LDw_g           : natural                   := 5
    );
    port (
        Clk         : in    std_logic;
        Rst         : in    std_logic;
        -- Dimensions of the image (1 to 65536), taken with Start
        Start       : in    std_logic;
        In_XSize    : in    std_logic_vector(16 downto 0);
        In_YSize    : in    std_logic_vector(16 downto 0);
        In_ZSize    : in    std_logic_vector(16 downto 0);
        -- Issue conditions of the image, valid from the clock cycle of Done (a pulse) until the
        -- next Start
        Done        : out   std_logic;
        Out_M       : out   std_logic_vector(16 downto 0);
        Out_Gap1    : out   std_logic;
        Out_RunRows : out   std_logic;
        Out_LFix    : out   std_logic_vector(7 downto 0);
        Out_LCross  : out   std_logic_vector(7 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_image_start is

    -- Saturation of the factors: a product of factors of which one reaches 2^SatW_c (and the other is not
    -- zero) exceeds every latency, as does the exact product
    constant SatW_c : positive := imageStartSatWidth(LRep_g, LDw_g);
    constant Sat_c  : positive := 2 ** SatW_c;
    constant OpW_c  : positive := SatW_c + 1;

    type State_t is (Idle_s, Mul_s, Cmp_s);

    type TwoProcess_r is record
        State   : State_t;
        Step    : natural range 0 to OpW_c - 1;
        -- Factors (BI: NX - 1 and M, BSQ: NX and NY), product, NX - 1, M < NZ
        A       : unsigned(OpW_c - 1 downto 0);
        B       : unsigned(OpW_c - 1 downto 0);
        Prod    : unsigned(2 * OpW_c - 1 downto 0);
        Xm1     : unsigned(OpW_c - 1 downto 0);
        MLtZ    : std_logic;
        -- Results
        Done    : std_logic;
        M       : unsigned(16 downto 0);
        Gap1    : std_logic;
        RunRows : std_logic;
        LFix    : natural range 0 to 255;
        LCross  : natural range 0 to 255;
    end record;

    signal r, r_next : TwoProcess_r;

    function sat (x : unsigned) return unsigned is
    begin
        if x >= Sat_c then
            return to_unsigned(Sat_c, OpW_c);
        end if;
        return resize(x, OpW_c);
    end function;

begin

    assert LRep_g < 256 and LDw_g < 256 and LWin_g < 256
        report "ocp_image_start: latencies must be below 256"
        severity failure;

    p_comb : process (all) is
        variable v         : TwoProcess_r;
        variable Nx_v      : unsigned(16 downto 0);
        variable Ny_v      : unsigned(16 downto 0);
        variable Nz_v      : unsigned(16 downto 0);
        variable M_v       : unsigned(16 downto 0);
        variable RowGap_v  : unsigned(2 * OpW_c downto 0);
        variable DiffGap_v : unsigned(2 * OpW_c downto 0);
        variable SameRep_v : boolean;
        variable CrossDw_v : boolean;
    begin
        v      := r;
        v.Done := '0';

        case r.State is

            when Idle_s =>
                if Start = '1' then
                    Nx_v := unsigned(In_XSize);
                    Ny_v := unsigned(In_YSize);
                    Nz_v := unsigned(In_ZSize);
                    -- M = min(sub-frame interleaving depth, NZ); BSQ: M is not used
                    if Nz_v < SubFrameDepth_g then
                        M_v := Nz_v;
                    else
                        M_v := to_unsigned(SubFrameDepth_g, 17);
                    end if;
                    v.M       := M_v;
                    v.Gap1    := toSl(Bsq_g or M_v = 1);
                    v.RunRows := toSl(Bsq_g or Nz_v = 1);
                    v.MLtZ    := toSl(Nz_v > SubFrameDepth_g);
                    v.Xm1     := sat(Nx_v - 1);
                    if Bsq_g then
                        v.A := sat(Nx_v);
                        v.B := sat(Ny_v);
                    else
                        v.A := sat(Nx_v - 1);
                        v.B := sat(M_v);
                    end if;
                    v.Prod  := (others => '0');
                    v.Step  := 0;
                    v.State := Mul_s;
                end if;

            when Mul_s =>
                -- Shift-and-add multiplication, most significant bit of B first
                v.Prod := shift_left(r.Prod, 1);
                if r.B(OpW_c - 1 - r.Step) = '1' then
                    v.Prod := shift_left(r.Prod, 1) + r.A;
                end if;
                if r.Step = OpW_c - 1 then
                    v.State := Cmp_s;
                else
                    v.Step := r.Step + 1;
                end if;

            when Cmp_s =>
                if Bsq_g then
                    RowGap_v  := resize(r.Xm1, RowGap_v'length);
                    DiffGap_v := resize(r.Prod, DiffGap_v'length);
                else
                    RowGap_v  := resize(r.Prod, RowGap_v'length);
                    DiffGap_v := resize(r.Prod, DiffGap_v'length) + 1;
                end if;
                SameRep_v := not RepIsSample_g and (WUsed_g or RowGap_v < LRep_g);
                CrossDw_v := PredBands_g > 0 and (Bsq_g or r.MLtZ = '1') and DiffGap_v < LDw_g;
                v.LFix    := 0;
                v.LCross  := 0;
                if r.Gap1 = '0' then
                    v.LFix := LWin_g;
                end if;
                if SameRep_v then
                    v.LFix := maximum(v.LFix, LRep_g);
                end if;
                if CrossRep_g then
                    v.LCross := LRep_g;
                end if;
                if CrossDw_v then
                    v.LCross := maximum(v.LCross, LDw_g);
                end if;
                v.Done  := '1';
                v.State := Idle_s;

            when others =>
                v.State := Idle_s;

        end case;

        r_next <= v;
    end process;

    Done        <= r.Done;
    Out_M       <= std_logic_vector(r.M);
    Out_Gap1    <= r.Gap1;
    Out_RunRows <= r.RunRows;
    Out_LFix    <= std_logic_vector(to_unsigned(r.LFix, 8));
    Out_LCross  <= std_logic_vector(to_unsigned(r.LCross, 8));

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.State <= Idle_s;
                r.Step  <= 0;
                r.Done  <= '0';
            end if;
        end if;
    end process;

end architecture;
