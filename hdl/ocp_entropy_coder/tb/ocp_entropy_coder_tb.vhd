---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of the entropy coders: drives the entropy coder input sequence of the reference model
-- (tb/golden/<config>/delta.txt) into the coder of a configuration, joins the codewords into a bit
-- stream and compares it byte by byte with the body of the image compressed by the CNES reference
-- software (compressed.bin from byte HeaderBytes_g), including the fill bits up to a multiple of
-- the output word size. Several images are coded one after the other; source gaps and sink stalls
-- are random.
--
-- Documentation: hdl/ocp_entropy_coder/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.textio.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_run_context;

library olo;
    use olo.olo_base_pkg_math.all;

library work;
    use work.ocp_pkg.all;
    use work.ocp_tb_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_entropy_coder_tb is
    generic (
        runner_cfg            : string;
        GoldenDir_g           : string   := "";
        -- Bytes of the header in compressed.bin (the body starts there)
        HeaderBytes_g         : natural  := 0;
        -- Number of images coded one after the other
        Images_g              : positive := 2;
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g            : natural  := 0;
        OutStallPct_g         : natural  := 0;
        -- Configuration
        XSize_g               : positive := 8;
        YSize_g               : positive := 8;
        ZSize_g               : positive := 4;
        DynamicRange_g        : positive := 16;
        OutputWordSize_g      : positive := 1;
        EntropyCoder_g        : string   := "SAMPLE_ADAPTIVE";
        AbsBitDepth_g         : positive := 1;
        RelBitDepth_g         : positive := 1;
        UnaryLimit_g          : positive := 16;
        RescaleCounterSize_g  : positive := 6;
        InitialCountExp_g     : positive := 1;
        AccuInitBandVarying_g : boolean  := false;
        AccuInit_g            : string   := "3";
        HybridAccuInit_g      : string   := "0";
        HybridAccuInitHigh_g  : string   := "0";
        BlockSize_g           : positive := 16;
        RestrictedCodes_g     : boolean  := false;
        RefInterval_g         : positive := 4096
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_entropy_coder_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant InW_c       : positive := maximum(DynamicRange_g, 16);
    constant ZW_c        : positive := log2ceil(ZSize_g + 1);

    signal Clk       : std_logic                            := '0';
    signal Rst       : std_logic                            := '1';
    signal In_Valid  : std_logic                            := '0';
    signal In_Ready  : std_logic;
    signal In_Data   : std_logic_vector(InW_c - 1 downto 0) := (others => '0');
    signal In_Kind   : std_logic_vector(1 downto 0)         := (others => '0');
    signal In_Band   : std_logic_vector(ZW_c - 1 downto 0)  := (others => '0');
    signal In_First  : std_logic                            := '0';
    signal In_Init   : std_logic                            := '0';
    signal In_Last   : std_logic                            := '0';
    signal Cw_Valid  : std_logic;
    signal Cw_Ready  : std_logic                            := '0';
    signal Cw_Data   : std_logic_vector(CwWidth_c - 1 downto 0);
    signal Cw_Length : std_logic_vector(CwLenWidth_c - 1 downto 0);
    signal Cw_Last   : std_logic;
    signal Ecc_Sec   : std_logic;
    signal Ecc_Ded   : std_logic;

    signal SinkDone : boolean := false;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    g_sample : if EntropyCoder_g = "SAMPLE_ADAPTIVE" generate

        i_dut : entity work.ocp_sample_adaptive_coder
            generic map (
                ZSize_g               => ZSize_g,
                DynamicRange_g        => DynamicRange_g,
                UnaryLimit_g          => UnaryLimit_g,
                RescaleCounterSize_g  => RescaleCounterSize_g,
                InitialCountExp_g     => InitialCountExp_g,
                AccuInitBandVarying_g => AccuInitBandVarying_g,
                AccuInit_g            => parseIntVec(AccuInit_g),
                AbsBitDepth_g         => AbsBitDepth_g,
                RelBitDepth_g         => RelBitDepth_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                In_Valid  => In_Valid,
                In_Ready  => In_Ready,
                In_Data   => In_Data,
                In_Kind   => In_Kind,
                In_Band   => In_Band,
                In_First  => In_First,
                In_Init   => In_Init,
                In_Last   => In_Last,
                Cw_Valid  => Cw_Valid,
                Cw_Ready  => Cw_Ready,
                Cw_Data   => Cw_Data,
                Cw_Length => Cw_Length,
                Cw_Last   => Cw_Last,
                Ecc_Sec   => Ecc_Sec,
                Ecc_Ded   => Ecc_Ded
            );

    end generate;

    g_hybrid : if EntropyCoder_g = "HYBRID" generate

        i_dut : entity work.ocp_hybrid_coder
            generic map (
                XSize_g              => XSize_g,
                YSize_g              => YSize_g,
                ZSize_g              => ZSize_g,
                DynamicRange_g       => DynamicRange_g,
                UnaryLimit_g         => UnaryLimit_g,
                RescaleCounterSize_g => RescaleCounterSize_g,
                InitialCountExp_g    => InitialCountExp_g,
                HybridAccuInit_g     => parseIntVec(HybridAccuInit_g),
                HybridAccuInitHigh_g => parseIntVec(HybridAccuInitHigh_g),
                AbsBitDepth_g        => AbsBitDepth_g,
                RelBitDepth_g        => RelBitDepth_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                In_Valid  => In_Valid,
                In_Ready  => In_Ready,
                In_Data   => In_Data,
                In_Kind   => In_Kind,
                In_Band   => In_Band,
                In_First  => In_First,
                In_Init   => In_Init,
                In_Last   => In_Last,
                Cw_Valid  => Cw_Valid,
                Cw_Ready  => Cw_Ready,
                Cw_Data   => Cw_Data,
                Cw_Length => Cw_Length,
                Cw_Last   => Cw_Last,
                Ecc_Sec   => Ecc_Sec,
                Ecc_Ded   => Ecc_Ded
            );

    end generate;

    g_block : if EntropyCoder_g = "BLOCK_ADAPTIVE" generate

        i_dut : entity work.ocp_block_adaptive_coder
            generic map (
                DynamicRange_g    => DynamicRange_g,
                BlockSize_g       => BlockSize_g,
                RestrictedCodes_g => RestrictedCodes_g,
                RefInterval_g     => RefInterval_g
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                In_Valid  => In_Valid,
                In_Ready  => In_Ready,
                In_Data   => In_Data,
                In_Last   => In_Last,
                Cw_Valid  => Cw_Valid,
                Cw_Ready  => Cw_Ready,
                Cw_Data   => Cw_Data,
                Cw_Length => Cw_Length,
                Cw_Last   => Cw_Last,
                Ecc_Sec   => Ecc_Sec,
                Ecc_Ded   => Ecc_Ded
            );

    end generate;

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_golden") then
                Rst <= '1';
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                Rst <= '0';
                wait until SinkDone;

                for i in 0 to 99 loop
                    wait until rising_edge(Clk);
                    check_value(Cw_Valid, '0', ERROR, "no codeword after the last image");
                    check_value(Ecc_Sec or Ecc_Ded, '0', ERROR, "no memory error");
                end loop;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Entropy coder input sequence of the reference model: "S <z> <t> <delta>" or "L <a|r> <value>",
    -- Images_g times
    p_source : process is
        variable Line_v : line;
        variable Kind_v : character;
        variable Sep_v  : character;
        variable Z_v    : integer;
        variable T_v    : integer;
        variable Val_v  : std_logic_vector(31 downto 0);

        file Ref_f : text;
    begin
        wait until Rst = '0';

        for img in 1 to Images_g loop
            file_open(Ref_f, GoldenDir_g & "/delta.txt", read_mode);

            while not endfile(Ref_f) loop
                readline(Ref_f, Line_v);
                read(Line_v, Kind_v);
                if Kind_v = 'S' then
                    read(Line_v, Z_v);
                    read(Line_v, T_v);
                    hread(Line_v, Val_v);
                    In_Kind  <= ItemSample_c;
                    In_Band  <= std_logic_vector(to_unsigned(Z_v, ZW_c));
                    In_First <= toSl(T_v = 0);
                    In_Init  <= toSl(T_v = 1);
                else
                    read(Line_v, Sep_v);
                    read(Line_v, Sep_v);
                    hread(Line_v, Val_v);
                    In_Kind  <= ItemAbsLimit_c when Sep_v = 'a' else ItemRelLimit_c;
                    In_First <= '0';
                    In_Init  <= '0';
                end if;
                In_Data <= Val_v(InW_c - 1 downto 0);
                In_Last <= toSl(endfile(Ref_f));

                while random(0, 99) < InGapPct_g loop
                    wait until rising_edge(Clk);
                end loop;

                In_Valid <= '1';
                wait until rising_edge(Clk) and In_Ready = '1';
                In_Valid <= '0';
            end loop;

            file_close(Ref_f);
        end loop;

        wait;
    end process;

    -- Bit stream of the codewords (the Cw_Length least significant bits, most significant bit
    -- first) against the body of the compressed image; the last codeword of an image is followed by
    -- fill bits up to a multiple of the output word size (counted from the start of the header)
    p_sink : process is
        variable Exp_v  : natural;
        variable Eof_v  : boolean;
        variable Cnt_v  : natural;
        variable Acc_v  : natural;
        variable NAcc_v : natural;

        file Ref_f : ByteFile_t;

        -- Compares the completed byte with the next byte of the reference
        procedure checkByte (img : positive) is
        begin
            check_value(not Eof_v, ERROR, "image " & to_string(img) & ": no byte beyond the end");
            check_value(Acc_v, Exp_v, ERROR, "image " & to_string(img) & " body byte " & to_string(Cnt_v));
            Cnt_v  := Cnt_v + 1;
            Acc_v  := 0;
            NAcc_v := 0;
            readByte(Ref_f, Exp_v, Eof_v);
        end procedure;

        variable Len_v   : natural;
        variable Total_v : natural;
    begin
        wait until Rst = '0';

        for img in 1 to Images_g loop
            file_open(Ref_f, GoldenDir_g & "/compressed.bin", read_mode);

            for i in 1 to HeaderBytes_g loop
                readByte(Ref_f, Exp_v, Eof_v);
            end loop;

            readByte(Ref_f, Exp_v, Eof_v);
            Cnt_v   := 0;
            Acc_v   := 0;
            NAcc_v  := 0;
            Total_v := HeaderBytes_g * 8;

            loop

                while random(0, 99) < OutStallPct_g loop
                    Cw_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                Cw_Ready <= '1';
                wait until rising_edge(Clk) and Cw_Valid = '1';
                Cw_Ready <= '0';

                Len_v := to_integer(unsigned(Cw_Length));
                check_value(Len_v <= CwWidth_c, ERROR, "codeword length");

                for b in Len_v - 1 downto 0 loop
                    Acc_v  := Acc_v * 2 + toInt(Cw_Data(b) = '1');
                    NAcc_v := NAcc_v + 1;
                    if NAcc_v = 8 then
                        checkByte(img);
                    end if;
                end loop;

                Total_v := Total_v + Len_v;
                exit when Cw_Last = '1';
            end loop;

            -- Fill bits ('0') up to a multiple of the output word size
            while Total_v mod (8 * OutputWordSize_g) /= 0 loop
                Acc_v   := Acc_v * 2;
                NAcc_v  := NAcc_v + 1;
                Total_v := Total_v + 1;
                if NAcc_v = 8 then
                    checkByte(img);
                end if;
            end loop;

            check_value(Eof_v, ERROR, "image " & to_string(img) & ": body complete after " & to_string(Cnt_v) &
                        " bytes");
            file_close(Ref_f);
            log(ID_SEQUENCER, "image " & to_string(img) & ": " & to_string(Cnt_v) & " body bytes checked");
        end loop;

        SinkDone <= true;
        wait;
    end process;

end architecture;
