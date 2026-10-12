---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_core: compresses the test image of a configuration (tb/golden/<config>) and
-- compares the compressed image byte by byte with the image compressed by the CNES reference
-- software, including the end of the image. The test sequencer runs jobs of one or several images;
-- a reset aborts a job.
--
-- * test_golden: several images one after the other (throughput against the model)
-- * test_ecc: a single and a double bit error injected into every memory of the configuration; a
--   corrected error leaves the compressed image unchanged, a detected double error is signalled,
--   and after a reset the next image is correct
-- * test_reset: resets at random times of an image (header, body, tail), each followed by a
--   correct image
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
        -- Number of images compressed one after the other (test_golden)
        Images_g               : positive := 2;
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g             : natural  := 0;
        OutStallPct_g          : natural  := 0;
        -- Largest number of cycles between the acceptance of the first and of the last sample of all
        -- images (throughput model tools/ocp_throughput.py); 0: not checked
        ExpCycles_g            : natural  := 0;
        -- Error injection channels of the memories of the configuration (test_ecc)
        EccChannels_g          : string   := "";
        -- Number of resets at random times (test_reset)
        Resets_g               : natural  := 8;
        -- Width of the compressed image interface in bits
        OutWidth_g             : positive := 8;
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

    signal Clk            : std_logic                                     := '0';
    signal Rst            : std_logic                                     := '1';
    signal In_Valid       : std_logic                                     := '0';
    signal In_Ready       : std_logic;
    signal In_Data        : std_logic_vector(DynamicRange_g - 1 downto 0) := (others => '0');
    signal Lim_Valid      : std_logic                                     := '0';
    signal Lim_Ready      : std_logic;
    signal Lim_Data       : std_logic_vector(15 downto 0)                 := (others => '0');
    signal Out_Valid      : std_logic;
    signal Out_Ready      : std_logic                                     := '0';
    signal Out_Data       : std_logic_vector(OutWidth_g - 1 downto 0);
    signal Out_Keep       : std_logic_vector(OutWidth_g / 8 - 1 downto 0);
    signal Out_Last       : std_logic;
    signal Ecc_Sec        : std_logic;
    signal Ecc_Ded        : std_logic;
    signal ErrInj_Channel : std_logic_vector(3 downto 0)                  := (others => '0');
    signal ErrInj_Double  : std_logic                                     := '0';
    signal ErrInj_Valid   : std_logic                                     := '0';

    -- Jobs: JobStart counts the started jobs; source and sink report the number of the job they
    -- finished (or that a reset aborted)
    signal JobStart   : natural  := 0;
    signal JobImages  : positive := 1;
    signal JobCompare : boolean  := true;
    signal SrcDone    : natural  := 0;
    signal SinkDone   : natural  := 0;

    -- Throughput: cycles of the first and the last accepted sample of a job, number of samples
    signal RateFirst : natural := 0;
    signal RateLast  : natural := 0;
    signal RateCount : natural := 0;

    -- Memory error pulses since the start of the job
    signal SecCount : natural := 0;
    signal DedCount : natural := 0;

    -- Cycles of the last complete job (test_reset)
    signal JobCycles : natural := 0;

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
            RefInterval_g          => RefInterval_g,
            OutWidth_g             => OutWidth_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            In_Valid       => In_Valid,
            In_Ready       => In_Ready,
            In_Data        => In_Data,
            Lim_Valid      => Lim_Valid,
            Lim_Ready      => Lim_Ready,
            Lim_Data       => Lim_Data,
            Out_Valid      => Out_Valid,
            Out_Ready      => Out_Ready,
            Out_Data       => Out_Data,
            Out_Keep       => Out_Keep,
            Out_Last       => Out_Last,
            Ecc_Sec        => Ecc_Sec,
            Ecc_Ded        => Ecc_Ded,
            ErrInj_Channel => ErrInj_Channel,
            ErrInj_Double  => ErrInj_Double,
            ErrInj_Valid   => ErrInj_Valid
        );

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
        variable Job_v : natural := 0;

        -- Reset of the DUT for some cycles
        procedure reset is
        begin
            Rst <= '1';

            for i in 1 to 5 loop
                wait until rising_edge(Clk);
            end loop;

            Rst <= '0';
            wait until rising_edge(Clk);
        end procedure;

        -- Starts a job of the source and the sink
        procedure start (images : positive; compare : boolean) is
        begin
            Job_v      := Job_v + 1;
            JobImages  <= images;
            JobCompare <= compare;
            JobStart   <= Job_v;
            wait until rising_edge(Clk);
        end procedure;

        -- Runs a job to its end
        procedure job (images : positive; compare : boolean) is
        begin
            start(images, compare);
            if SinkDone /= Job_v then
                wait until SinkDone = Job_v;
            end if;
            wait until rising_edge(Clk);
        end procedure;

        -- After the end of a job: no further output
        procedure checkIdle is
        begin

            for i in 0 to 99 loop
                wait until rising_edge(Clk);
                check_value(Out_Valid, '0', ERROR, "no output after the last image");
            end loop;

        end procedure;

        -- Injects an error into the next write of a memory
        procedure inject (channel : natural; double : std_logic) is
        begin
            ErrInj_Channel <= std_logic_vector(to_unsigned(channel, 4));
            ErrInj_Double  <= double;
            ErrInj_Valid   <= '1';
            wait until rising_edge(Clk);
            ErrInj_Valid   <= '0';
        end procedure;

        variable Channels_v : integer_vector(0 to 15);
        variable NCh_v      : natural;
        variable Wait_v     : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_golden") then
                reset;
                job(Images_g, true);

                -- Throughput
                log(ID_SEQUENCER, "accepted " & to_string(RateCount) & " samples in " &
                    to_string(RateLast - RateFirst + 1) & " cycles");
                if ExpCycles_g > 0 then
                    check_value(RateLast - RateFirst <= ExpCycles_g, ERROR,
                                "cycles between the first and the last sample at most " & to_string(ExpCycles_g));
                end if;
                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                checkIdle;

            elsif run("test_ecc") then
                Channels_v := (others => 0);
                NCh_v      := 0;
                if EccChannels_g /= "" then
                    NCh_v                      := parseIntVec(EccChannels_g)'length;
                    Channels_v(0 to NCh_v - 1) := parseIntVec(EccChannels_g);
                end if;

                for i in 0 to NCh_v - 1 loop
                    -- Single bit error: corrected, the compressed image is unchanged
                    reset;
                    inject(Channels_v(i), '0');
                    job(1, true);
                    check_value(SecCount > 0, ERROR, "channel " & to_string(Channels_v(i)) & ": corrected error");
                    check_value(DedCount, 0, ERROR, "channel " & to_string(Channels_v(i)) & ": no double error");

                    -- Double bit error: detected; the compressed image is not compared
                    reset;
                    inject(Channels_v(i), '1');
                    job(1, false);
                    check_value(DedCount > 0, ERROR, "channel " & to_string(Channels_v(i)) & ": detected error");
                end loop;

                -- After a reset the next image is correct
                reset;
                job(1, true);
                check_value(SecCount + DedCount, 0, ERROR, "no memory error after the injections");
                checkIdle;

            elsif run("test_reset") then
                -- Duration of a complete image
                reset;
                job(1, true);

                for i in 1 to Resets_g loop
                    -- Reset at a random time of an image (also in the tail after the last sample)
                    Wait_v := random(0, JobCycles + 20);
                    reset;
                    start(1, true);

                    for c in 1 to Wait_v loop
                        wait until rising_edge(Clk);
                    end loop;

                    log(ID_SEQUENCER, "reset after " & to_string(Wait_v) & " of " & to_string(JobCycles) & " cycles");

                    -- The next image is correct
                    reset;
                    if SinkDone /= Job_v then
                        wait until SinkDone = Job_v;
                    end if;
                    job(1, true);
                end loop;

                check_value(SecCount + DedCount, 0, ERROR, "no memory error");
                checkIdle;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Image samples (little-endian 8, 16 or 32-bit containers), JobImages times per job
    p_source : process is
        variable Byte_v  : natural;
        variable Eof_v   : boolean;
        variable Smp_v   : std_logic_vector(31 downto 0);
        variable Abort_v : boolean;

        file Img_f : ByteFile_t;
    begin
        wait on JobStart;
        Abort_v := false;

        for img in 1 to JobImages loop
            file_open(Img_f, GoldenDir_g & "/image.raw", read_mode);

            loop
                Smp_v := (others => '0');

                for b in 0 to Bytes_c - 1 loop
                    readByte(Img_f, Byte_v, Eof_v);
                    Smp_v(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(Byte_v, 8));
                end loop;

                exit when Eof_v;

                while random(0, 99) < InGapPct_g and Rst = '0' loop
                    wait until rising_edge(Clk);
                end loop;

                In_Valid <= '1';
                In_Data  <= Smp_v(DynamicRange_g - 1 downto 0);
                wait until rising_edge(Clk) and (In_Ready = '1' or Rst = '1');
                In_Valid <= '0';
                Abort_v  := Rst = '1';
                exit when Abort_v;
            end loop;

            file_close(Img_f);
            exit when Abort_v;
        end loop;

        SrcDone <= JobStart;
    end process;

    -- Throughput: cycle of the first and the last accepted sample of a job
    p_rate : process is
        variable Cycle_v : natural := 0;
        variable Count_v : natural := 0;
        variable Job_v   : natural := 0;
    begin
        wait until rising_edge(Clk);
        if JobStart /= Job_v then
            Job_v     := JobStart;
            Count_v   := 0;
            RateCount <= 0;
        end if;
        if In_Valid = '1' and In_Ready = '1' then
            if Count_v = 0 then
                RateFirst <= Cycle_v;
            end if;
            RateLast  <= Cycle_v;
            Count_v   := Count_v + 1;
            RateCount <= Count_v;
        end if;
        Cycle_v := Cycle_v + 1;
    end process;

    -- Memory error pulses since the start of the job, cycles of the job
    p_ecc : process is
        variable Job_v    : natural := 0;
        variable Cycles_v : natural := 0;
    begin
        wait until rising_edge(Clk);
        if JobStart /= Job_v then
            Job_v    := JobStart;
            SecCount <= 0;
            DedCount <= 0;
            Cycles_v := 0;
        else
            if Ecc_Sec = '1' then
                SecCount <= SecCount + 1;
            end if;
            if Ecc_Ded = '1' then
                DedCount <= DedCount + 1;
            end if;
            Cycles_v := Cycles_v + 1;
            if SinkDone /= Job_v then
                JobCycles <= Cycles_v;
            end if;
        end if;
    end process;

    -- Periodic error limit values (16-bit big-endian), JobImages times per job
    p_limits : process is
        variable Hi_v    : natural;
        variable Lo_v    : natural;
        variable Eof_v   : boolean;
        variable Abort_v : boolean;

        file Lim_f : ByteFile_t;
    begin
        if not Periodic_c then
            wait;
        end if;
        wait on JobStart;
        Abort_v := false;

        for img in 1 to JobImages loop
            file_open(Lim_f, GoldenDir_g & "/error_limits.bin", read_mode);

            loop
                readByte(Lim_f, Hi_v, Eof_v);
                readByte(Lim_f, Lo_v, Eof_v);
                exit when Eof_v;
                Lim_Valid <= '1';
                Lim_Data  <= std_logic_vector(to_unsigned(Hi_v * 256 + Lo_v, 16));
                wait until rising_edge(Clk) and (Lim_Ready = '1' or Rst = '1');
                Lim_Valid <= '0';
                Abort_v   := Rst = '1';
                exit when Abort_v;
            end loop;

            file_close(Lim_f);
            exit when Abort_v;
        end loop;

    end process;

    -- Compressed image of the CNES reference software: the valid bytes of every word, first byte in
    -- the most significant bits; the last word of an image carries the last flag. A job without
    -- comparison only waits for the last word of every image.
    p_sink : process is
        variable Exp_v   : natural;
        variable Eof_v   : boolean;
        variable Cnt_v   : natural;
        variable Hi_v    : natural;
        variable Abort_v : boolean;

        file Ref_f : ByteFile_t;
    begin
        wait on JobStart;
        Abort_v := false;

        for img in 1 to JobImages loop
            file_open(Ref_f, GoldenDir_g & "/compressed.bin", read_mode);
            Cnt_v := 0;
            readByte(Ref_f, Exp_v, Eof_v);

            loop
                exit when JobCompare and Eof_v;

                while random(0, 99) < OutStallPct_g and Rst = '0' loop
                    Out_Ready <= '0';
                    wait until rising_edge(Clk);
                end loop;

                Out_Ready <= '1';
                wait until rising_edge(Clk) and (Out_Valid = '1' or Rst = '1');
                Out_Ready <= '0';
                Abort_v   := Rst = '1';
                exit when Abort_v;

                if JobCompare then

                    for b in 0 to OutWidth_g / 8 - 1 loop
                        Hi_v := OutWidth_g - 1 - 8 * b;
                        if Out_Keep(OutWidth_g / 8 - 1 - b) = '1' then
                            check_value(not Eof_v, ERROR, "image " & to_string(img) & ": no byte beyond the end");
                            check_value(to_integer(unsigned(Out_Data(Hi_v downto Hi_v - 7))), Exp_v, ERROR,
                                        "image " & to_string(img) & " byte " & to_string(Cnt_v));
                            Cnt_v := Cnt_v + 1;
                            readByte(Ref_f, Exp_v, Eof_v);
                        end if;
                    end loop;

                    check_value(Out_Last, toSl(Eof_v), ERROR,
                                "image " & to_string(img) & " byte " & to_string(Cnt_v) & ": last flag");
                else
                    exit when Out_Last = '1';
                end if;
            end loop;

            file_close(Ref_f);
            exit when Abort_v;
            log(ID_SEQUENCER, "image " & to_string(img) & ": " & to_string(Cnt_v) & " bytes checked");
        end loop;

        SinkDone <= JobStart;
    end process;

end architecture;
