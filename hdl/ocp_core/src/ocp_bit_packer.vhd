---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Bit packer: appends codewords of up to CwWidth_c bits, one per clock cycle, to the compressed
-- image and outputs it in words of OutWidth_g bits, the first byte in bits 7:0 and the first bit of
-- every byte in its most significant bit (CCSDS 123.0-B-2 1.6.3). After the last codeword of an image
-- it appends fill bits up to a multiple of the output word size of the standard (CCSDS 123.0-B-2
-- 5.3.1.2, OutputWordSize_g bytes); the last interface word of an image marks its valid bytes with
-- Out_Keep, and the next image starts with a new interface word.
--
-- The codewords are written into a circular bit buffer. The position of a codeword only depends on
-- the lengths of the codewords before it, so its alignment to the position is pipelined.
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

library work;
    use work.ocp_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_bit_packer is
    generic (
        OutputWordSize_g : positive range 1 to 8 := 1;
        OutWidth_g       : positive              := 8
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Codewords: the In_Length least significant bits of In_Data, most significant bit first
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Data   : in    std_logic_vector(CwWidth_c - 1 downto 0);
        In_Length : in    std_logic_vector(CwLenWidth_c - 1 downto 0);
        In_Last   : in    std_logic;
        -- Compressed image: byte n in Out_Data(8n + 7 downto 8n), first bit of a byte in its most
        -- significant bit; Out_Keep(n) marks byte n valid
        Out_Valid : out   std_logic;
        Out_Ready : in    std_logic;
        Out_Data  : out   std_logic_vector(OutWidth_g - 1 downto 0);
        Out_Keep  : out   std_logic_vector(OutWidth_g / 8 - 1 downto 0);
        Out_Last  : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_bit_packer is

    constant OW_c     : positive := OutWidth_g;
    constant Fill_c   : positive := 8 * OutputWordSize_g;
    -- Circular buffer: a codeword in flight, the fill bits and two output words
    constant BufW_c   : positive := 2 ** log2ceil(CwWidth_c + Fill_c + 2 * OW_c);
    constant PosW_c   : positive := log2ceil(BufW_c);
    constant PtrW_c   : positive := PosW_c + 1;
    constant Words_c  : positive := BufW_c / OW_c;
    constant Margin_c : positive := CwWidth_c + Fill_c + OW_c;
    constant Fine_c   : positive := PosW_c / 2;

    subtype Ptr_t is unsigned(PtrW_c - 1 downto 0);

    type TwoProcess_r is record
        -- Allocation: position of the next codeword, bits of the image modulo the fill unit, image
        -- end pending (fill bits)
        WpA      : Ptr_t;
        FillMod  : natural range 0 to Fill_c - 1;
        FillPend : std_logic;
        -- Stage 1: codeword in stream order (first bit at index 0), stages 2 and 3: rotated to the
        -- buffer position (coarse, fine)
        V1       : std_logic;
        Bits1    : std_logic_vector(CwWidth_c - 1 downto 0);
        Mask1    : std_logic_vector(CwWidth_c - 1 downto 0);
        Pos1     : unsigned(PosW_c - 1 downto 0);
        End1     : Ptr_t;
        V2       : std_logic;
        Bits2    : std_logic_vector(BufW_c - 1 downto 0);
        Mask2    : std_logic_vector(BufW_c - 1 downto 0);
        Pos2     : unsigned(PosW_c - 1 downto 0);
        End2     : Ptr_t;
        V3       : std_logic;
        Bits3    : std_logic_vector(BufW_c - 1 downto 0);
        Mask3    : std_logic_vector(BufW_c - 1 downto 0);
        End3     : Ptr_t;
        -- Buffer, written up to WpC, read from Rp
        Buf      : std_logic_vector(BufW_c - 1 downto 0);
        WpC      : Ptr_t;
        Rp       : Ptr_t;
        -- End positions of the images in the buffer (queue of two)
        EndValid : std_logic_vector(0 to 1);
        End0     : Ptr_t;
        End1q    : Ptr_t;
        -- Output word
        OutValid : std_logic;
        OutData  : std_logic_vector(OW_c - 1 downto 0);
        OutKeep  : std_logic_vector(OW_c / 8 - 1 downto 0);
        OutLast  : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    function reverse (x : std_logic_vector) return std_logic_vector is
        variable R_v : std_logic_vector(x'length - 1 downto 0);
    begin

        for i in 0 to x'length - 1 loop
            R_v(i) := x(x'low + x'length - 1 - i);
        end loop;

        return R_v;
    end function;

    -- Interface word from a buffer word in stream order: byte n holds the stream bits 8n to 8n + 7,
    -- the first of them in its most significant bit
    function toBytes (x : std_logic_vector) return std_logic_vector is
        variable R_v : std_logic_vector(x'length - 1 downto 0);
    begin

        for n in 0 to x'length / 8 - 1 loop

            for i in 0 to 7 loop
                R_v(8 * n + 7 - i) := x(x'low + 8 * n + i);
            end loop;

        end loop;

        return R_v;
    end function;

    -- Mask of the n least significant bits
    function lowMask (n : natural) return std_logic_vector is
        variable M_v : std_logic_vector(CwWidth_c - 1 downto 0) := (others => '0');
    begin

        for i in 0 to CwWidth_c - 1 loop
            if i < n then
                M_v(i) := '1';
            end if;
        end loop;

        return M_v;
    end function;

    -- (a + b) mod Fill_c for a < Fill_c, b <= CwWidth_c
    function addMod (a : natural; b : natural) return natural is
    begin
        return (a + b) mod Fill_c;
    end function;

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable Len_v   : natural range 0 to CwWidth_c;
        variable Fill_v  : natural range 0 to Fill_c - 1;
        variable End_v   : Ptr_t;
        variable Avail_v : Ptr_t;
        variable Rest_v  : Ptr_t;
        variable Word_v  : natural range 0 to Words_c - 1;
        variable Data_v  : std_logic_vector(OW_c - 1 downto 0);
        variable Bytes_v : natural range 0 to OW_c / 8;
        variable Push_v  : boolean;
    begin
        v      := r;
        Push_v := false;
        End_v  := r.WpA;

        if Out_Ready = '1' then
            v.OutValid := '0';
        end if;

        -------------------------------------------------------------------------------------------
        -- Allocation: a codeword per cycle while the buffer has room; after the last codeword of an
        -- image the fill bits, then the next image starts at an interface word boundary
        -------------------------------------------------------------------------------------------
        In_Ready <= '0';
        v.V1     := '0';
        if r.FillPend = '1' then
            -- Fill bits (5.3.1.2) and end of the image; waits for room in the queue of image ends
            if r.EndValid(1) = '0' then
                Fill_v  := (Fill_c - r.FillMod) mod Fill_c;
                End_v   := r.WpA + Fill_v;
                v.V1    := '1';
                v.Bits1 := (others => '0');
                v.Mask1 := lowMask(Fill_v);
                v.Pos1  := r.WpA(PosW_c - 1 downto 0);
                -- Written up to the next interface word: the next image starts there
                v.End1 := End_v + ((OW_c - to_integer(End_v mod OW_c)) mod OW_c);
                -- Entered into the queue of image ends after the output (below)
                Push_v     := true;
                v.WpA      := End_v + ((OW_c - to_integer(End_v mod OW_c)) mod OW_c);
                v.FillMod  := 0;
                v.FillPend := '0';
            end if;
        elsif r.WpA - r.Rp <= BufW_c - Margin_c then
            In_Ready <= '1';
            if In_Valid = '1' then
                Len_v := minimum(to_integer(unsigned(In_Length)), CwWidth_c);
                -- Stream order: bit m of the codeword is In_Data(Len - 1 - m)
                v.V1       := '1';
                v.Bits1    := std_logic_vector(shift_right(unsigned(reverse(In_Data)), CwWidth_c - Len_v));
                v.Mask1    := lowMask(Len_v);
                v.Pos1     := r.WpA(PosW_c - 1 downto 0);
                v.End1     := r.WpA + Len_v;
                v.WpA      := r.WpA + Len_v;
                v.FillMod  := addMod(r.FillMod, Len_v);
                v.FillPend := In_Last;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Alignment to the buffer position, write into the buffer
        -------------------------------------------------------------------------------------------
        v.V2    := r.V1;
        v.Bits2 := std_logic_vector(rotate_left(resize(unsigned(r.Bits1), BufW_c),
                                                to_integer(r.Pos1(PosW_c - 1 downto Fine_c)) * 2 ** Fine_c));
        v.Mask2 := std_logic_vector(rotate_left(resize(unsigned(r.Mask1), BufW_c),
                                                to_integer(r.Pos1(PosW_c - 1 downto Fine_c)) * 2 ** Fine_c));
        v.Pos2  := r.Pos1;
        v.End2  := r.End1;

        v.V3    := r.V2;
        v.Bits3 := std_logic_vector(rotate_left(unsigned(r.Bits2), to_integer(r.Pos2(Fine_c - 1 downto 0))));
        v.Mask3 := std_logic_vector(rotate_left(unsigned(r.Mask2), to_integer(r.Pos2(Fine_c - 1 downto 0))));
        v.End3  := r.End2;

        if r.V3 = '1' then
            v.Buf := (r.Buf and not r.Mask3) or (r.Bits3 and r.Mask3);
            v.WpC := r.End3;
        end if;

        -------------------------------------------------------------------------------------------
        -- Output: a full word, or the last word of an image once all its bits are written
        -------------------------------------------------------------------------------------------
        if v.OutValid = '0' then
            Avail_v := r.WpC - r.Rp;
            Rest_v  := r.End0 - r.Rp;
            Word_v  := to_integer(r.Rp(PosW_c - 1 downto 0)) / OW_c;
            Data_v  := (others => '0');

            for w in 0 to Words_c - 1 loop
                if w = Word_v then
                    Data_v := toBytes(r.Buf((w + 1) * OW_c - 1 downto w * OW_c));
                end if;
            end loop;

            if r.EndValid(0) = '1' and Rest_v <= OW_c then
                -- The image ends in this word
                if Rest_v <= Avail_v then
                    Bytes_v := to_integer(Rest_v) / 8;

                    for b in 0 to OW_c / 8 - 1 loop
                        v.OutKeep(b) := toSl(b < Bytes_v);
                        if b >= Bytes_v then
                            Data_v(8 * b + 7 downto 8 * b) := (others => '0');
                        end if;
                    end loop;

                    v.OutValid    := '1';
                    v.OutData     := Data_v;
                    v.OutLast     := '1';
                    v.Rp          := r.Rp + OW_c;
                    v.EndValid(0) := r.EndValid(1);
                    v.EndValid(1) := '0';
                    v.End0        := r.End1q;
                end if;
            elsif Avail_v >= OW_c then
                v.OutValid := '1';
                v.OutData  := Data_v;
                v.OutKeep  := (others => '1');
                v.OutLast  := '0';
                v.Rp       := r.Rp + OW_c;
            end if;
        end if;

        -- Queue of image ends: the end of the image whose fill bits were allocated, after the output
        -- has taken the end of the previous image in the same cycle
        if Push_v then
            if v.EndValid(0) = '0' then
                v.EndValid(0) := '1';
                v.End0        := End_v;
            else
                v.EndValid(1) := '1';
                v.End1q       := End_v;
            end if;
        end if;

        r_next <= v;
    end process;

    Out_Valid <= r.OutValid;
    Out_Data  <= r.OutData;
    Out_Keep  <= r.OutKeep;
    Out_Last  <= r.OutLast;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.WpA      <= (others => '0');
                r.WpC      <= (others => '0');
                r.Rp       <= (others => '0');
                r.FillMod  <= 0;
                r.FillPend <= '0';
                r.V1       <= '0';
                r.V2       <= '0';
                r.V3       <= '0';
                r.EndValid <= "00";
                r.OutValid <= '0';
                r.OutLast  <= '0';
            end if;
        end if;
    end process;

end architecture;
