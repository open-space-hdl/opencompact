---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_bit_packer.
--
-- * test_random: random codewords (lengths 0 to CwWidth_c bits) of random images (1 to
--   MaxCodewords_g codewords) are packed; the sink builds the expected bytes from the same random
--   sequence (same seeds), appends the fill bits up to a multiple of the output word size and checks
--   every interface word, its valid bytes (Out_Keep) and the last flag. Source gaps and sink stalls
--   are random; small images with sink stalls queue several image ends in the packer.
-- * test_byte_order: one image of the numbered bytes 1, 2, 3, ... (2 OutWidth_g / 8 - 1 bytes) as
--   8-bit codewords; byte n of every word must be in Out_Data(8n + 7 downto 8n) and the valid bytes
--   of the last word contiguous from byte 0.
--
-- Documentation: hdl/ocp_core/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_run_context;

library work;
    use work.ocp_pkg.all;
    use work.ocp_tb_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_bit_packer_tb is
    generic (
        runner_cfg       : string;
        OutputWordSize_g : positive := 1;
        OutWidth_g       : positive := 8;
        -- Number of images and largest number of codewords per image
        Images_g         : positive := 50;
        MaxCodewords_g   : positive := 40;
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g       : natural  := 0;
        OutStallPct_g    : natural  := 0;
        Seed_g           : positive := 1
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_bit_packer_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := OutWidth_g / 8;
    constant MaxBytes_c  : positive := (MaxCodewords_g * CwWidth_c) / 8 + 2 * OutputWordSize_g;
    -- test_byte_order: numbered bytes of the image, and with the fill bytes up to a multiple of the
    -- output word size
    constant OrdBytes_c  : positive := 2 * Bytes_c - 1;
    constant OrdTotal_c  : positive := OrdBytes_c + (OutputWordSize_g - OrdBytes_c mod OutputWordSize_g) mod
                                       OutputWordSize_g;

    signal Clk       : std_logic                                   := '0';
    signal Rst       : std_logic                                   := '1';
    signal In_Valid  : std_logic                                   := '0';
    signal In_Ready  : std_logic;
    signal In_Data   : std_logic_vector(CwWidth_c - 1 downto 0)    := (others => '0');
    signal In_Length : std_logic_vector(CwLenWidth_c - 1 downto 0) := (others => '0');
    signal In_Last   : std_logic                                   := '0';
    signal Out_Valid : std_logic;
    signal Out_Ready : std_logic                                   := '0';
    signal Out_Data  : std_logic_vector(OutWidth_g - 1 downto 0);
    signal Out_Keep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal Out_Last  : std_logic;

    signal SinkDone  : boolean := false;
    signal ByteOrder : boolean := false;

    -- Random codeword sequence: the same seeds in the source and in the sink give the same sequence
    type Rng_t is record
        S1 : positive;
        S2 : positive;
    end record;

    procedure randInt (rng : inout Rng_t; lo : integer; hi : integer; v : out integer) is
        variable R_v : real;
    begin
        uniform(rng.S1, rng.S2, R_v);
        v := lo + integer(floor(R_v * real(hi - lo + 1)));
        if v > hi then
            v := hi;
        end if;
    end procedure;

    -- Codeword of an image: random length (more often short, at least one bit for the first codeword
    -- of an image), random bits
    procedure randCodeword (rng : inout Rng_t; first : boolean; data : out std_logic_vector; len : out natural) is
        variable Sel_v : integer;
        variable Len_v : integer;
        variable Bit_v : integer;
    begin
        randInt(rng, 0, 9, Sel_v);
        if Sel_v < 6 then
            randInt(rng, 0, 16, Len_v);
        else
            randInt(rng, 0, CwWidth_c, Len_v);
        end if;
        if first and Len_v = 0 then
            Len_v := 1;
        end if;
        data := (data'range => '0');

        for i in 0 to Len_v - 1 loop
            randInt(rng, 0, 1, Bit_v);
            data(i) := toSl(Bit_v = 1);
        end loop;

        len := Len_v;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_bit_packer
        generic map (
            OutputWordSize_g => OutputWordSize_g,
            OutWidth_g       => OutWidth_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => In_Valid,
            In_Ready  => In_Ready,
            In_Data   => In_Data,
            In_Length => In_Length,
            In_Last   => In_Last,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready,
            Out_Data  => Out_Data,
            Out_Keep  => Out_Keep,
            Out_Last  => Out_Last
        );

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_random") or run("test_byte_order") then
                ByteOrder <= running_test_case = "test_byte_order";
                Rst       <= '1';
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                Rst       <= '0';
                wait until SinkDone;

                for i in 0 to 99 loop
                    wait until rising_edge(Clk);
                    check_value(Out_Valid, '0', ERROR, "no output after the last image");
                end loop;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Random images of random codewords, or the image of numbered bytes (test_byte_order)
    p_source : process is
        variable Rng_v  : Rng_t := (Seed_g, 7);
        variable N_v    : integer;
        variable Data_v : std_logic_vector(CwWidth_c - 1 downto 0);
        variable Len_v  : natural;
    begin
        wait until Rst = '0';

        if ByteOrder then

            -- Codeword i: the byte i as 8 bits, most significant bit first
            for i in 1 to OrdBytes_c loop
                In_Valid  <= '1';
                In_Data   <= std_logic_vector(to_unsigned(i, CwWidth_c));
                In_Length <= std_logic_vector(to_unsigned(8, CwLenWidth_c));
                In_Last   <= toSl(i = OrdBytes_c);
                wait until rising_edge(Clk) and In_Ready = '1';
                In_Valid  <= '0';
            end loop;

            wait;
        end if;

        for img in 1 to Images_g loop
            randInt(Rng_v, 1, MaxCodewords_g, N_v);

            for i in 1 to N_v loop
                randCodeword(Rng_v, i = 1, Data_v, Len_v);

                while random(0, 99) < InGapPct_g loop
                    wait until rising_edge(Clk);
                end loop;

                In_Valid  <= '1';
                In_Data   <= Data_v;
                In_Length <= std_logic_vector(to_unsigned(Len_v, CwLenWidth_c));
                In_Last   <= toSl(i = N_v);
                wait until rising_edge(Clk) and In_Ready = '1';
                In_Valid  <= '0';
            end loop;

        end loop;

        wait;
    end process;

    -- Expected bytes of every image from the same random sequence (or the numbered bytes), checked
    -- word by word: byte n of a word in Out_Data(8n + 7 downto 8n)
    p_sink : process is
        type ByteArr_t is array (0 to MaxBytes_c - 1) of natural range 0 to 255;

        variable Rng_v    : Rng_t := (Seed_g, 7);
        variable N_v      : integer;
        variable Data_v   : std_logic_vector(CwWidth_c - 1 downto 0);
        variable Len_v    : natural;
        variable Exp_v    : ByteArr_t;
        variable NExp_v   : natural;
        variable Acc_v    : natural;
        variable NAcc_v   : natural;
        variable Bits_v   : natural;
        variable Pos_v    : natural;
        variable Valid_v  : natural;
        variable Images_v : positive;
    begin
        wait until Rst = '0';
        Images_v := Images_g;
        if ByteOrder then
            Images_v := 1;
        end if;

        for img in 1 to Images_v loop
            -- Expected bytes: codewords most significant bit first, then fill bits
            NExp_v := 0;
            Acc_v  := 0;
            NAcc_v := 0;
            Bits_v := 0;
            N_v    := 0;
            if ByteOrder then

                -- Numbered bytes 1, 2, 3, ..., then the fill bytes
                for i in 0 to OrdTotal_c - 1 loop
                    Exp_v(i) := 0;
                    if i < OrdBytes_c then
                        Exp_v(i) := i + 1;
                    end if;
                end loop;

                NExp_v := OrdTotal_c;
            else
                randInt(Rng_v, 1, MaxCodewords_g, N_v);
            end if;

            for i in 1 to N_v loop
                randCodeword(Rng_v, i = 1, Data_v, Len_v);

                for b in Len_v - 1 downto 0 loop
                    Acc_v  := Acc_v * 2 + toInt(Data_v(b) = '1');
                    NAcc_v := NAcc_v + 1;
                    Bits_v := Bits_v + 1;
                    if NAcc_v = 8 then
                        Exp_v(NExp_v) := Acc_v;
                        NExp_v        := NExp_v + 1;
                        Acc_v         := 0;
                        NAcc_v        := 0;
                    end if;
                end loop;

            end loop;

            while Bits_v mod (8 * OutputWordSize_g) /= 0 loop
                Acc_v  := Acc_v * 2;
                NAcc_v := NAcc_v + 1;
                Bits_v := Bits_v + 1;
                if NAcc_v = 8 then
                    Exp_v(NExp_v) := Acc_v;
                    NExp_v        := NExp_v + 1;
                    Acc_v         := 0;
                    NAcc_v        := 0;
                end if;
            end loop;

            -- Interface words: all bytes valid except in the last word of the image
            Pos_v := 0;

            while Pos_v < NExp_v loop

                while random(0, 99) < OutStallPct_g loop
                    Out_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                Out_Ready <= '0';

                Valid_v := minimum(Bytes_c, NExp_v - Pos_v);

                if ByteOrder then
                    log(ID_SEQUENCER, "Out_Data x""" & to_hstring(Out_Data) & """, Out_Keep """ &
                                      to_string(Out_Keep) & """");
                end if;

                for b in 0 to Bytes_c - 1 loop
                    check_value(Out_Keep(b), toSl(b < Valid_v), ERROR,
                                "image " & to_string(img) & " byte " & to_string(Pos_v + b) & ": keep");
                    if b < Valid_v then
                        check_value(to_integer(unsigned(Out_Data(8 * b + 7 downto 8 * b))), Exp_v(Pos_v + b), ERROR,
                                    "image " & to_string(img) & " byte " & to_string(Pos_v + b));
                    end if;
                end loop;

                Pos_v := Pos_v + Valid_v;
                check_value(Out_Last, toSl(Pos_v = NExp_v), ERROR,
                            "image " & to_string(img) & " byte " & to_string(Pos_v) & ": last flag");
            end loop;

        end loop;

        log(ID_SEQUENCER, to_string(Images_v) & " images checked");
        SinkDone <= true;
        wait;
    end process;

end architecture;
