---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Bit packer: appends variable-length codewords (up to 64 bits) to the compressed image and outputs
-- it as a byte stream. After the last codeword of an image it appends fill bits up to the next
-- output word boundary (CCSDS 123.0-B-2 5.2.2, 5.4.3.2.4.4, 5.4.3.3.5.4.5, 5.4.3.4.3.2) and marks
-- the last byte. The last codeword of an image must not be empty.
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
entity ocp_bit_packer is
    generic (
        OutputWordSize_g : positive range 1 to 8 := 1
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
        -- Compressed image
        Out_Valid : out   std_logic;
        Out_Ready : in    std_logic;
        Out_Data  : out   std_logic_vector(7 downto 0);
        Out_Last  : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_bit_packer is

    constant BufW_c : positive := CwWidth_c + 8;

    type TwoProcess_r is record
        Buf      : std_logic_vector(BufW_c - 1 downto 0);
        Count    : natural range 0 to BufW_c;
        Flush    : std_logic;
        ByteMod  : natural range 0 to OutputWordSize_g - 1;
        OutValid : std_logic;
        OutData  : std_logic_vector(7 downto 0);
        OutLast  : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Len_v  : natural range 0 to CwWidth_c;
        variable Emit_v : boolean;
        variable Byte_v : std_logic_vector(7 downto 0);
        variable Mask_v : unsigned(CwWidth_c downto 0);
    begin
        v := r;

        if Out_Ready = '1' then
            v.OutValid := '0';
        end if;

        -- Accept a codeword while the buffer can take 64 further bits
        In_Ready <= '0';
        if r.Flush = '0' and r.Count <= 8 then
            In_Ready <= '1';
            if In_Valid = '1' then
                Len_v                         := minimum(to_integer(unsigned(In_Length)), CwWidth_c);
                v.Buf                         := std_logic_vector(shift_left(unsigned(r.Buf), Len_v));
                Mask_v                        := shift_left(to_unsigned(1, CwWidth_c + 1), Len_v) - 1;
                v.Buf(CwWidth_c - 1 downto 0) := v.Buf(CwWidth_c - 1 downto 0) or
                                                 (In_Data and std_logic_vector(Mask_v(CwWidth_c - 1 downto 0)));
                v.Count                       := r.Count + Len_v;
                v.Flush                       := In_Last;
            end if;
        end if;

        -- Output one byte per cycle; after the last codeword the fill bits up to the word boundary
        if v.OutValid = '0' then
            Emit_v := false;
            Byte_v := (others => '0');
            if v.Count >= 8 then
                Byte_v  := std_logic_vector(resize(shift_right(unsigned(v.Buf), v.Count - 8), 8));
                v.Count := v.Count - 8;
                Emit_v  := true;
            elsif v.Flush = '1' and v.Count > 0 then
                Byte_v  := std_logic_vector(shift_left(unsigned(v.Buf(7 downto 0)), 8 - v.Count));
                v.Count := 0;
                Emit_v  := true;
            elsif v.Flush = '1' and r.ByteMod /= 0 then
                Emit_v := true;
            end if;
            if Emit_v then
                v.OutValid := '1';
                v.OutData  := Byte_v;
                v.OutLast  := '0';
                if r.ByteMod = OutputWordSize_g - 1 then
                    v.ByteMod := 0;
                    if v.Flush = '1' and v.Count = 0 then
                        v.OutLast := '1';
                        v.Flush   := '0';
                    end if;
                else
                    v.ByteMod := r.ByteMod + 1;
                end if;
            end if;
        end if;

        r_next <= v;
    end process;

    Out_Valid <= r.OutValid;
    Out_Data  <= r.OutData;
    Out_Last  <= r.OutLast;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Count    <= 0;
                r.Flush    <= '0';
                r.ByteMod  <= 0;
                r.OutValid <= '0';
                r.OutLast  <= '0';
            end if;
        end if;
    end process;

end architecture;
