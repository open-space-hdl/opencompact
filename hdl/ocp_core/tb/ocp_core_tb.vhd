---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_core: compresses the test image of a configuration (tb/golden/<config>) and
-- compares the compressed image byte by byte with the image compressed by the CNES reference
-- software, including the end of the image. Several images are compressed one after the other.
--
-- Documentation: hdl/ocp_core/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

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
entity ocp_core_tb is
    generic (
        runner_cfg             : string;
        GoldenDir_g            : string   := "";
        -- Number of images compressed one after the other
        Images_g               : positive := 2;
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g             : natural  := 0;
        OutStallPct_g          : natural  := 0;
        -- Configuration
        XSize_g                : positive := 8;
        YSize_g                : positive := 8;
        ZSize_g                : positive := 4;
        DynamicRange_g         : positive := 16;
        SignedSamples_g        : boolean  := false;
        UserData_g             : natural  := 0;
        EncodingOrder_g        : string   := "BI";
        SubFrameDepth_g        : positive := 4;
        OutputWordSize_g       : positive := 1;
        EntropyCoder_g         : string   := "SAMPLE_ADAPTIVE";
        SupTableCount_g        : natural  := 0;
        SupTableData_g         : string   := "00";
        PredictionBands_g      : natural  := 3;
        PredictionMode_g       : string   := "FULL";
        LocalSum_g             : string   := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive := 64;
        WeightResolution_g     : positive := 13;
        WeightUpdateInterval_g : positive := 6;
        WeightUpdateVmin_g     : integer  := -1;
        WeightUpdateVmax_g     : integer  := 3;
        WeightExpOffsetsUsed_g : boolean  := false;
        WeightExpOffsetTable_g : boolean  := false;
        WeightExpOffsets_g     : string   := "0";
        CustomWeights_g        : boolean  := false;
        WeightInitTable_g      : boolean  := false;
        WeightInitResolution_g : natural  := 0;
        WeightInitValues_g     : string   := "0";
        Fidelity_g             : string   := "LOSSLESS";
        PeriodicUpdate_g       : boolean  := false;
        UpdatePeriodExp_g      : natural  := 0;
        AbsBandDependent_g     : boolean  := false;
        AbsBitDepth_g          : positive := 1;
        AbsErrorLimits_g       : string   := "0";
        RelBandDependent_g     : boolean  := false;
        RelBitDepth_g          : positive := 1;
        RelErrorLimits_g       : string   := "0";
        SampleRepResolution_g  : natural  := 0;
        DampingBandVarying_g   : boolean  := false;
        DampingTable_g         : boolean  := false;
        Damping_g              : string   := "0";
        OffsetBandVarying_g    : boolean  := false;
        OffsetTable_g          : boolean  := false;
        Offset_g               : string   := "0";
        UnaryLimit_g           : positive := 16;
        RescaleCounterSize_g   : positive := 6;
        InitialCountExp_g      : positive := 1;
        AccuInitBandVarying_g  : boolean  := false;
        AccuInitTable_g        : boolean  := false;
        AccuInit_g             : string   := "3";
        HybridAccuInit_g       : string   := "0";
        HybridAccuInitHigh_g   : string   := "0";
        BlockSize_g            : positive := 16;
        RestrictedCodes_g      : boolean  := false;
        RefInterval_g          : positive := 4096
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_core_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := 1 + toInt(DynamicRange_g > 8) + 2 * toInt(DynamicRange_g > 16);
    constant Periodic_c  : boolean  := PeriodicUpdate_g and Fidelity_g /= "LOSSLESS";

    signal Clk       : std_logic                                     := '0';
    signal Rst       : std_logic                                     := '1';
    signal In_Valid  : std_logic                                     := '0';
    signal In_Ready  : std_logic;
    signal In_Data   : std_logic_vector(DynamicRange_g - 1 downto 0) := (others => '0');
    signal Lim_Valid : std_logic                                     := '0';
    signal Lim_Ready : std_logic;
    signal Lim_Data  : std_logic_vector(15 downto 0)                 := (others => '0');
    signal Out_Valid : std_logic;
    signal Out_Ready : std_logic                                     := '0';
    signal Out_Data  : std_logic_vector(7 downto 0);
    signal Out_Last  : std_logic;
    signal Ecc_Sec   : std_logic;
    signal Ecc_Ded   : std_logic;

    signal SinkDone : boolean := false;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_core
        generic map (
            XSize_g                => XSize_g,
            YSize_g                => YSize_g,
            ZSize_g                => ZSize_g,
            DynamicRange_g         => DynamicRange_g,
            SignedSamples_g        => SignedSamples_g,
            UserData_g             => UserData_g,
            EncodingOrder_g        => EncodingOrder_g,
            SubFrameDepth_g        => SubFrameDepth_g,
            OutputWordSize_g       => OutputWordSize_g,
            EntropyCoder_g         => EntropyCoder_g,
            SupTableCount_g        => SupTableCount_g,
            SupTableData_g         => hexToSlv(SupTableData_g),
            PredictionBands_g      => PredictionBands_g,
            PredictionMode_g       => PredictionMode_g,
            LocalSum_g             => LocalSum_g,
            RegisterSize_g         => RegisterSize_g,
            WeightResolution_g     => WeightResolution_g,
            WeightUpdateInterval_g => WeightUpdateInterval_g,
            WeightUpdateVmin_g     => WeightUpdateVmin_g,
            WeightUpdateVmax_g     => WeightUpdateVmax_g,
            WeightExpOffsetsUsed_g => WeightExpOffsetsUsed_g,
            WeightExpOffsetTable_g => WeightExpOffsetTable_g,
            WeightExpOffsets_g     => parseIntVec(WeightExpOffsets_g),
            CustomWeights_g        => CustomWeights_g,
            WeightInitTable_g      => WeightInitTable_g,
            WeightInitResolution_g => WeightInitResolution_g,
            WeightInitValues_g     => parseIntVec(WeightInitValues_g),
            Fidelity_g             => Fidelity_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsBitDepth_g          => AbsBitDepth_g,
            AbsErrorLimits_g       => parseIntVec(AbsErrorLimits_g),
            RelBandDependent_g     => RelBandDependent_g,
            RelBitDepth_g          => RelBitDepth_g,
            RelErrorLimits_g       => parseIntVec(RelErrorLimits_g),
            SampleRepResolution_g  => SampleRepResolution_g,
            DampingBandVarying_g   => DampingBandVarying_g,
            DampingTable_g         => DampingTable_g,
            Damping_g              => parseIntVec(Damping_g),
            OffsetBandVarying_g    => OffsetBandVarying_g,
            OffsetTable_g          => OffsetTable_g,
            Offset_g               => parseIntVec(Offset_g),
            UnaryLimit_g           => UnaryLimit_g,
            RescaleCounterSize_g   => RescaleCounterSize_g,
            InitialCountExp_g      => InitialCountExp_g,
            AccuInitBandVarying_g  => AccuInitBandVarying_g,
            AccuInitTable_g        => AccuInitTable_g,
            AccuInit_g             => parseIntVec(AccuInit_g),
            HybridAccuInit_g       => parseIntVec(HybridAccuInit_g),
            HybridAccuInitHigh_g   => parseIntVec(HybridAccuInitHigh_g),
            BlockSize_g            => BlockSize_g,
            RestrictedCodes_g      => RestrictedCodes_g,
            RefInterval_g          => RefInterval_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => In_Valid,
            In_Ready  => In_Ready,
            In_Data   => In_Data,
            Lim_Valid => Lim_Valid,
            Lim_Ready => Lim_Ready,
            Lim_Data  => Lim_Data,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready,
            Out_Data  => Out_Data,
            Out_Last  => Out_Last,
            Ecc_Sec   => Ecc_Sec,
            Ecc_Ded   => Ecc_Ded
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
            if run("test_golden") then
                Rst <= '1';
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                Rst <= '0';
                wait until SinkDone;

                for i in 0 to 99 loop
                    wait until rising_edge(Clk);
                    check_value(Out_Valid, '0', ERROR, "no output after the last image");
                    check_value(Ecc_Sec or Ecc_Ded, '0', ERROR, "no memory error");
                end loop;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Image samples (little-endian 8, 16 or 32-bit containers), Images_g times
    p_source : process is
        variable Byte_v : natural;
        variable Eof_v  : boolean;
        variable Smp_v  : std_logic_vector(31 downto 0);

        file Img_f : ByteFile_t;
    begin
        wait until Rst = '0';

        for img in 1 to Images_g loop
            file_open(Img_f, GoldenDir_g & "/image.raw", read_mode);

            loop
                Smp_v := (others => '0');

                for b in 0 to Bytes_c - 1 loop
                    readByte(Img_f, Byte_v, Eof_v);
                    Smp_v(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(Byte_v, 8));
                end loop;

                exit when Eof_v;

                while random(0, 99) < InGapPct_g loop
                    wait until rising_edge(Clk);
                end loop;

                In_Valid <= '1';
                In_Data  <= Smp_v(DynamicRange_g - 1 downto 0);
                wait until rising_edge(Clk) and In_Ready = '1';
                In_Valid <= '0';
            end loop;

            file_close(Img_f);
        end loop;

        wait;
    end process;

    -- Periodic error limit values (16-bit big-endian), Images_g times
    p_limits : process is
        variable Hi_v  : natural;
        variable Lo_v  : natural;
        variable Eof_v : boolean;

        file Lim_f : ByteFile_t;
    begin
        if not Periodic_c then
            wait;
        end if;
        wait until Rst = '0';

        for img in 1 to Images_g loop
            file_open(Lim_f, GoldenDir_g & "/error_limits.bin", read_mode);

            loop
                readByte(Lim_f, Hi_v, Eof_v);
                readByte(Lim_f, Lo_v, Eof_v);
                exit when Eof_v;
                Lim_Valid <= '1';
                Lim_Data  <= std_logic_vector(to_unsigned(Hi_v * 256 + Lo_v, 16));
                wait until rising_edge(Clk) and Lim_Ready = '1';
                Lim_Valid <= '0';
            end loop;

            file_close(Lim_f);
        end loop;

        wait;
    end process;

    -- Compressed image of the CNES reference software
    p_sink : process is
        variable Exp_v   : natural;
        variable Next_v  : natural;
        variable Eof_v   : boolean;
        variable NextE_v : boolean;
        variable Cnt_v   : natural;

        file Ref_f : ByteFile_t;
    begin
        wait until Rst = '0';

        for img in 1 to Images_g loop
            file_open(Ref_f, GoldenDir_g & "/compressed.bin", read_mode);
            Cnt_v := 0;
            readByte(Ref_f, Exp_v, Eof_v);

            while not Eof_v loop
                readByte(Ref_f, Next_v, NextE_v);

                while random(0, 99) < OutStallPct_g loop
                    Out_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                Out_Ready <= '1';
                wait until rising_edge(Clk) and Out_Valid = '1';
                Out_Ready <= '0';
                check_value(to_integer(unsigned(Out_Data)), Exp_v, ERROR,
                            "image " & to_string(img) & " byte " & to_string(Cnt_v));
                check_value(Out_Last, toSl(NextE_v), ERROR,
                            "image " & to_string(img) & " byte " & to_string(Cnt_v) & ": last flag");
                Cnt_v     := Cnt_v + 1;
                Exp_v     := Next_v;
                Eof_v     := NextE_v;
            end loop;

            file_close(Ref_f);
            log(ID_SEQUENCER, "image " & to_string(img) & ": " & to_string(Cnt_v) & " bytes checked");
        end loop;

        SinkDone <= true;
        wait;
    end process;

end architecture;
