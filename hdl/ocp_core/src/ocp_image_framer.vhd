---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Image framer (CO-4): checks the image end marker In_Last of the input against the number of
-- samples of an image. A sample with an early In_Last ends its image there: it goes to the
-- predictor with Smp_End, which makes it the last item of the image. After a last sample without
-- In_Last the samples up to the next In_Last are discarded. The error flag of every image
-- accompanies the last word of its compressed image.
--
-- Documentation: hdl/ocp_core/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_attribute.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_image_framer is
    generic (
        XSize_g         : positive range 1 to 65536 := 8;
        YSize_g         : positive range 1 to 65536 := 8;
        ZSize_g         : positive range 1 to 65536 := 4;
        -- Runtime configuration: the dimensions of every image from the configuration inputs (the
        -- generics are the maxima)
        RuntimeConfig_g : boolean                   := false
    );
    port (
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Samples of the user with the image end marker and its error flag (the data goes to the
        -- predictor directly)
        In_Valid      : in    std_logic;
        In_Ready      : out   std_logic;
        In_Last       : in    std_logic;
        In_Error      : in    std_logic;
        -- Error limit values of the user
        Lim_Valid     : in    std_logic;
        Lim_Ready     : out   std_logic;
        -- Samples and error limit values to the predictor; Smp_End with a sample that ends its image
        -- before its last sample
        Smp_Valid     : out   std_logic;
        Smp_Ready     : in    std_logic;
        Smp_End       : out   std_logic;
        Val_Valid     : out   std_logic;
        Val_Ready     : in    std_logic;
        -- Compressed image (handshake of the bit packer output) and its error flag
        Out_Valid     : in    std_logic;
        Out_Ready     : in    std_logic;
        Out_Last      : in    std_logic;
        Out_Error     : out   std_logic;
        -- Framing error (pulse)
        Ev_ImageError : out   std_logic;
        -- Runtime configuration: dimensions of the next image (1 to the maxima), taken with its first
        -- sample (Cfg_Take of the predictor marks the first sample of an image)
        Cfg_Take      : in    std_logic                     := '0';
        Cfg_XSize     : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_YSize     : in    std_logic_vector(16 downto 0) := (others => '0');
        Cfg_ZSize     : in    std_logic_vector(16 downto 0) := (others => '0')
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_image_framer is

    -- Index of the last sample of an image (X Y Z - 1)
    constant CntW_c : positive := log2ceil(XSize_g) + log2ceil(YSize_g) + log2ceil(ZSize_g) + 1;

    function lastIndex return unsigned is
        variable N_v : unsigned(3 * CntW_c - 1 downto 0);
    begin
        N_v := to_unsigned(XSize_g, CntW_c) * to_unsigned(YSize_g, CntW_c) * to_unsigned(ZSize_g, CntW_c);
        return resize(N_v - 1, CntW_c);
    end function;

    constant Last_c : unsigned(CntW_c - 1 downto 0) := lastIndex;

    -- Runtime configuration: position of the sample in a mixed-radix count (x fastest, then y, then z),
    -- whatever the input order; the image ends with the sample at the last index of all three
    constant XW_c : positive := log2ceil(XSize_g + 1);
    constant YW_c : positive := log2ceil(YSize_g + 1);
    constant ZW_c : positive := log2ceil(ZSize_g + 1);

    -- Error flags of the images whose input ended and whose compressed image is not yet output; the
    -- pointers have one bit more than the index, so their difference is the number of flags
    constant Depth_c : positive := 16;
    constant PtrW_c  : positive := log2ceil(Depth_c);

    -- Run: samples go to the predictor; Discard: samples up to the next In_Last are discarded
    type State_t is (Run_s, Discard_s);

    -- Clock cycles without error limit value after an early image end: a source that delivers the values
    -- ahead drops those of the aborted image on Ev_ImageError before the core takes the next one
    constant LimHold_c : positive := 3;

    type TwoProcess_r is record
        State  : State_t;
        Remain : unsigned(CntW_c - 1 downto 0);
        Hold   : natural range 0 to LimHold_c;
        Err    : std_logic_vector(Depth_c - 1 downto 0);
        WrPtr  : unsigned(PtrW_c downto 0);
        RdPtr  : unsigned(PtrW_c downto 0);
        Ev     : std_logic;
        -- Runtime configuration: position of the next sample and last index of every dimension
        Cx     : unsigned(XW_c - 1 downto 0);
        Cy     : unsigned(YW_c - 1 downto 0);
        Cz     : unsigned(ZW_c - 1 downto 0);
        XMax   : unsigned(XW_c - 1 downto 0);
        YMax   : unsigned(YW_c - 1 downto 0);
        ZMax   : unsigned(ZW_c - 1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    -- The error flags are registers: a memory would need SECDED protection
    attribute ram_style of r    : signal is "registers";
    attribute ramstyle of r     : signal is "logic";
    attribute syn_ramstyle of r : signal is "registers";

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable Push_v  : boolean;
        variable PushE_v : std_logic;
        variable Last_v  : boolean;
        variable Cx_v    : unsigned(XW_c - 1 downto 0);
        variable Cy_v    : unsigned(YW_c - 1 downto 0);
        variable Cz_v    : unsigned(ZW_c - 1 downto 0);
        variable XMax_v  : unsigned(XW_c - 1 downto 0);
        variable YMax_v  : unsigned(YW_c - 1 downto 0);
        variable ZMax_v  : unsigned(ZW_c - 1 downto 0);
    begin
        v    := r;
        v.Ev := '0';
        -- Last sample of the image: the count of the generics, or the position in the dimensions of the
        -- image (the first sample of an image starts at position 0 with the dimensions taken with it)
        if RuntimeConfig_g then
            if Cfg_Take = '1' then
                Cx_v   := (others => '0');
                Cy_v   := (others => '0');
                Cz_v   := (others => '0');
                XMax_v := resize(unsigned(Cfg_XSize) - 1, XW_c);
                YMax_v := resize(unsigned(Cfg_YSize) - 1, YW_c);
                ZMax_v := resize(unsigned(Cfg_ZSize) - 1, ZW_c);
            else
                Cx_v   := r.Cx;
                Cy_v   := r.Cy;
                Cz_v   := r.Cz;
                XMax_v := r.XMax;
                YMax_v := r.YMax;
                ZMax_v := r.ZMax;
            end if;
            Last_v := Cx_v = XMax_v and Cy_v = YMax_v and Cz_v = ZMax_v;
        else
            Last_v := r.Remain = 0;
        end if;
        if r.Hold > 0 then
            v.Hold := r.Hold - 1;
        end if;
        Push_v  := false;
        PushE_v := '0';

        In_Ready  <= '0';
        Lim_Ready <= '0';
        Smp_Valid <= '0';
        Val_Valid <= '0';

        case r.State is

            when Run_s =>
                -- A sample is taken while there is room for the error flag of its image
                if r.WrPtr - r.RdPtr < Depth_c then
                    In_Ready  <= Smp_Ready;
                    Smp_Valid <= In_Valid;
                    if In_Valid = '1' and Smp_Ready = '1' then
                        if RuntimeConfig_g then
                            v.XMax := XMax_v;
                            v.YMax := YMax_v;
                            v.ZMax := ZMax_v;
                            if Last_v or In_Last = '1' then
                                v.Cx := (others => '0');
                                v.Cy := (others => '0');
                                v.Cz := (others => '0');
                            elsif Cx_v /= XMax_v then
                                v.Cx := Cx_v + 1;
                            elsif Cy_v /= YMax_v then
                                v.Cx := (others => '0');
                                v.Cy := Cy_v + 1;
                            else
                                v.Cx := (others => '0');
                                v.Cy := (others => '0');
                                v.Cz := Cz_v + 1;
                            end if;
                        end if;
                        if Last_v then
                            -- Last sample of the image: without In_Last the image end was lost; with
                            -- In_Last and In_Error the complete image ends with an error (CO-FR-08)
                            Push_v   := true;
                            PushE_v  := not In_Last or In_Error;
                            v.Remain := Last_c;
                            if In_Last = '0' then
                                v.Ev    := '1';
                                v.State := Discard_s;
                            elsif In_Error = '1' then
                                v.Ev := '1';
                            end if;
                        elsif In_Last = '1' then
                            -- Image end before the last sample: the predictor ends the image with this
                            -- sample (CO-FR-03), the next sample starts a new image
                            Push_v   := true;
                            PushE_v  := '1';
                            v.Remain := Last_c;
                            v.Ev     := '1';
                            v.Hold   := LimHold_c;
                        else
                            v.Remain := r.Remain - 1;
                        end if;
                    end if;
                end if;
                if r.Hold = 0 then
                    Lim_Ready <= Val_Ready;
                    Val_Valid <= Lim_Valid;
                end if;

            when Discard_s =>
                In_Ready <= '1';
                if In_Valid = '1' and In_Last = '1' then
                    v.State := Run_s;
                end if;

            when others =>
                v.State := Run_s;

        end case;

        -- Error flags in the order of the images: written with the last sample, read with the last word
        if Push_v then
            v.Err(to_integer(r.WrPtr(PtrW_c - 1 downto 0))) := PushE_v;
            v.WrPtr                                         := r.WrPtr + 1;
        end if;
        if Out_Valid = '1' and Out_Ready = '1' and Out_Last = '1' then
            v.RdPtr := r.RdPtr + 1;
        end if;

        Out_Error <= Out_Valid and Out_Last and r.Err(to_integer(r.RdPtr(PtrW_c - 1 downto 0)));

        -- Early end of an image: a sample with In_Last before the last sample of the image
        Smp_End <= In_Last when not Last_v else '0';

        r_next <= v;
    end process;

    Ev_ImageError <= r.Ev;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.State  <= Run_s;
                r.Remain <= Last_c;
                r.Hold   <= 0;
                r.WrPtr  <= (others => '0');
                r.RdPtr  <= (others => '0');
                r.Ev     <= '0';
                if RuntimeConfig_g then
                    r.Cx <= (others => '0');
                    r.Cy <= (others => '0');
                    r.Cz <= (others => '0');
                end if;
            end if;
        end if;
    end process;

end architecture;
