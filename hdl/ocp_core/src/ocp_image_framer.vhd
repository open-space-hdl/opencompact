---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Image framer (CO-4): checks the image end marker In_Last of the input against the number of
-- samples of an image. An image that ends early is aborted: once the earlier images have left the
-- entropy coder, the predictor and the entropy coder are cleared and the image ends at the bit
-- packer. After a last sample without In_Last the samples up to the next In_Last are discarded.
-- The error flag of every image accompanies the last word of its compressed image.
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
        XSize_g : positive range 1 to 65536 := 8;
        YSize_g : positive range 1 to 65536 := 8;
        ZSize_g : positive range 1 to 65536 := 4
    );
    port (
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Samples of the user with the image end marker (the data goes to the predictor directly)
        In_Valid      : in    std_logic;
        In_Ready      : out   std_logic;
        In_Last       : in    std_logic;
        -- Error limit values of the user
        Lim_Valid     : in    std_logic;
        Lim_Ready     : out   std_logic;
        -- Samples and error limit values to the predictor
        Smp_Valid     : out   std_logic;
        Smp_Ready     : in    std_logic;
        Val_Valid     : out   std_logic;
        Val_Ready     : in    std_logic;
        -- Image start at the predictor, image end at the input of the bit packer, body of an image at
        -- the input of the bit packer (after its header)
        Img_Start     : in    std_logic;
        Img_End       : in    std_logic;
        Img_Body      : in    std_logic;
        -- Abort: clears the predictor and the entropy coder, then ends the image at the bit packer
        Flush         : out   std_logic;
        End_Valid     : out   std_logic;
        End_Ready     : in    std_logic;
        -- Compressed image (handshake of the bit packer output) and its error flag
        Out_Valid     : in    std_logic;
        Out_Ready     : in    std_logic;
        Out_Last      : in    std_logic;
        Out_Error     : out   std_logic;
        -- Framing error (pulse)
        Ev_ImageError : out   std_logic
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

    -- Error flags of the images whose input ended and whose compressed image is not yet output
    constant Depth_c : positive := 16;
    constant PtrW_c  : positive := log2ceil(Depth_c);
    constant CtrW_c  : positive := log2ceil(Depth_c + 2);

    -- Run: samples go to the predictor; Drain: abort, waiting until the predictor and the entropy
    -- coder hold only the aborted image; Close: end of the aborted image at the bit packer;
    -- Discard: samples up to the next In_Last are discarded
    type State_t is (Run_s, Drain_s, Close_s, Discard_s);

    type TwoProcess_r is record
        State  : State_t;
        Remain : unsigned(CntW_c - 1 downto 0);
        Images : unsigned(CtrW_c - 1 downto 0);
        Err    : std_logic_vector(Depth_c - 1 downto 0);
        WrPtr  : unsigned(PtrW_c - 1 downto 0);
        RdPtr  : unsigned(PtrW_c - 1 downto 0);
        Level  : unsigned(CtrW_c - 1 downto 0);
        Flush  : std_logic;
        Ev     : std_logic;
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
        variable Pop_v   : boolean;
    begin
        v       := r;
        v.Flush := '0';
        v.Ev    := '0';
        Push_v  := false;
        PushE_v := '0';

        In_Ready  <= '0';
        Lim_Ready <= '0';
        Smp_Valid <= '0';
        Val_Valid <= '0';
        End_Valid <= '0';

        case r.State is

            when Run_s =>
                -- A sample is taken while there is room for the error flag of its image
                if r.Level < Depth_c then
                    In_Ready  <= Smp_Ready;
                    Smp_Valid <= In_Valid;
                    if In_Valid = '1' and Smp_Ready = '1' then
                        if r.Remain = 0 then
                            -- Last sample of the image: without In_Last the image end was lost
                            Push_v   := true;
                            PushE_v  := not In_Last;
                            v.Remain := Last_c;
                            if In_Last = '0' then
                                v.Ev    := '1';
                                v.State := Discard_s;
                            end if;
                        elsif In_Last = '1' then
                            -- Image end before the last sample: the image is aborted
                            Push_v   := true;
                            PushE_v  := '1';
                            v.Remain := Last_c;
                            v.Ev     := '1';
                            v.State  := Drain_s;
                        else
                            v.Remain := r.Remain - 1;
                        end if;
                    end if;
                end if;
                Lim_Ready <= Val_Ready;
                Val_Valid <= Lim_Valid;

            when Drain_s =>
                -- The earlier images have left the entropy coder: clear the predictor and the coder
                if r.Images = 1 then
                    v.Flush := '1';
                    v.State := Close_s;
                end if;

            when Close_s =>
                -- After the header of the aborted image: its end at the bit packer (fill bits follow)
                if r.Flush = '0' and Img_Body = '1' then
                    End_Valid <= '1';
                    if End_Ready = '1' then
                        v.State := Run_s;
                    end if;
                end if;

            when Discard_s =>
                In_Ready <= '1';
                if In_Valid = '1' and In_Last = '1' then
                    v.State := Run_s;
                end if;

            when others =>
                v.State := Run_s;

        end case;

        -- Images in the predictor, the entropy coder and the codeword path to the bit packer
        if Img_Start = '1' and Img_End = '0' then
            v.Images := r.Images + 1;
        elsif Img_Start = '0' and Img_End = '1' then
            v.Images := r.Images - 1;
        end if;

        -- Error flags in the order of the images: written with the last sample, read with the last word
        Pop_v := Out_Valid = '1' and Out_Ready = '1' and Out_Last = '1';
        if Push_v then
            v.Err(to_integer(r.WrPtr)) := PushE_v;
            v.WrPtr                    := r.WrPtr + 1;
        end if;
        if Pop_v then
            v.RdPtr := r.RdPtr + 1;
        end if;
        if Push_v and not Pop_v then
            v.Level := r.Level + 1;
        elsif Pop_v and not Push_v then
            v.Level := r.Level - 1;
        end if;

        Out_Error <= Out_Valid and Out_Last and r.Err(to_integer(r.RdPtr));

        r_next <= v;
    end process;

    Flush         <= r.Flush;
    Ev_ImageError <= r.Ev;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.State  <= Run_s;
                r.Remain <= Last_c;
                r.Images <= (others => '0');
                r.WrPtr  <= (others => '0');
                r.RdPtr  <= (others => '0');
                r.Level  <= (others => '0');
                r.Flush  <= '0';
                r.Ev     <= '0';
            end if;
        end if;
    end process;

end architecture;
