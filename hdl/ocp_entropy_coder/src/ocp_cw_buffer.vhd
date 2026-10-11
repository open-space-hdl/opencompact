---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Codeword buffer of the entropy coders: consecutive codewords are concatenated into one codeword
-- of up to CwWidth_c bits before they enter a SECDED-protected FIFO. A FIFO entry then holds
-- several short codewords, so the buffer absorbs a stop of the bit packer (the header of the next
-- image) and the bit packer takes several codewords per clock cycle afterwards. A codeword with the
-- last flag ends the concatenation.
--
-- Documentation: hdl/ocp_entropy_coder/docs/specification.md

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
entity ocp_cw_buffer is
    generic (
        Depth_g    : positive := 16;
        RamStyle_g : string   := "auto"
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Codewords; In_Level counts the occupied entries including the concatenation register, a
        -- codeword is accepted while In_Level < Depth_g
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Data   : in    std_logic_vector(CwWidth_c - 1 downto 0);
        In_Length : in    std_logic_vector(CwLenWidth_c - 1 downto 0);
        In_Last   : in    std_logic;
        In_Level  : out   std_logic_vector(log2ceil(Depth_g + 2) - 1 downto 0);
        -- Concatenated codewords
        Cw_Valid  : out   std_logic;
        Cw_Ready  : in    std_logic;
        Cw_Data   : out   std_logic_vector(CwWidth_c - 1 downto 0);
        Cw_Length : out   std_logic_vector(CwLenWidth_c - 1 downto 0);
        Cw_Last   : out   std_logic;
        -- Memory errors (pulses)
        Ecc_Sec   : out   std_logic;
        Ecc_Ded   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_cw_buffer is

    constant FifoW_c : positive := CwWidth_c + CwLenWidth_c + 1;

    type TwoProcess_r is record
        Held : std_logic;
        Data : std_logic_vector(CwWidth_c - 1 downto 0);
        Len  : unsigned(CwLenWidth_c - 1 downto 0);
        Last : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    signal FifoInValid : std_logic;
    signal FifoInData  : std_logic_vector(FifoW_c - 1 downto 0);
    signal FifoLevel   : std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
    signal FifoOutData : std_logic_vector(FifoW_c - 1 downto 0);
    signal Ready       : std_logic;

    -- Codeword without bits beyond its length
    function masked (d : std_logic_vector; n : natural) return std_logic_vector is
        variable M_v : std_logic_vector(CwWidth_c - 1 downto 0) := (others => '0');
    begin

        for i in 0 to CwWidth_c - 1 loop
            if i < n then
                M_v(i) := d(d'low + i);
            end if;
        end loop;

        return M_v;
    end function;

begin

    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable Len_v : natural range 0 to CwWidth_c;
    begin
        v           := r;
        FifoInValid <= '0';
        FifoInData  <= r.Last & std_logic_vector(r.Len) & r.Data;

        if r.Held = '1' and r.Last = '1' then
            -- The last codeword of an image leaves at once
            FifoInValid <= '1';
            v.Held      := '0';
        end if;

        if Ready = '1' and In_Valid = '1' then
            Len_v := to_integer(unsigned(In_Length));
            if r.Held = '1' and r.Last = '0' and to_integer(r.Len) + Len_v <= CwWidth_c then
                -- Concatenation: the new codeword follows the held one
                v.Data := std_logic_vector(shift_left(unsigned(r.Data), Len_v)) or masked(In_Data, Len_v);
                v.Len  := r.Len + Len_v;
                v.Last := In_Last;
            else
                if r.Held = '1' and r.Last = '0' then
                    FifoInValid <= '1';
                end if;
                v.Held := '1';
                v.Data := masked(In_Data, Len_v);
                v.Len  := unsigned(In_Length);
                v.Last := In_Last;
            end if;
        end if;

        r_next <= v;
    end process;

    Ready    <= toSl(to_integer(unsigned(FifoLevel)) + 1 < Depth_g);
    In_Ready <= Ready;
    In_Level <= std_logic_vector(resize(unsigned(FifoLevel), In_Level'length) + toInt(r.Held = '1'));

    Cw_Data   <= FifoOutData(CwWidth_c - 1 downto 0);
    Cw_Length <= FifoOutData(CwWidth_c + CwLenWidth_c - 1 downto CwWidth_c);
    Cw_Last   <= FifoOutData(FifoW_c - 1);

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Held <= '0';
                r.Last <= '0';
            end if;
        end if;
    end process;

    i_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g    => FifoW_c,
            Depth_g    => Depth_g,
            RamStyle_g => RamStyle_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            In_Data    => FifoInData,
            In_Valid   => FifoInValid,
            In_Ready   => open,
            In_Level   => FifoLevel,
            Out_Data   => FifoOutData,
            Out_Valid  => Cw_Valid,
            Out_Ready  => Cw_Ready,
            Out_EccSec => Ecc_Sec,
            Out_EccDed => Ecc_Ded
        );

end architecture;
