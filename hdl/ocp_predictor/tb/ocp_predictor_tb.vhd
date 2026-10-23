---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_predictor: compresses the test image of a configuration (tb/golden/<config>)
-- and compares the entropy coder input sequence (mapped quantizer indices, error limit values,
-- band, first sample and last sample flags) with the sequence of the reference model.
--
-- Documentation: hdl/ocp_predictor/docs/verification_plan.md

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
entity ocp_predictor_tb is
    generic (
        runner_cfg             : string;
        GoldenDir_g            : string   := "";
        -- Back pressure: probability (percent) of an idle cycle of the source and of the sink
        InGapPct_g             : natural  := 0;
        OutStallPct_g          : natural  := 0;
        -- Expected cycles between the acceptance of the first and of the last sample (throughput
        -- model tools/ocp_throughput.py); 0: not checked
        ExpCycles_g            : natural  := 0;
        -- Expected cycles between the first and the last item at the output (stride order, throughput
        -- model); 0: not checked
        ExpOutCycles_g         : natural  := 0;
        -- Configuration
        XSize_g                : positive := 8;
        YSize_g                : positive := 8;
        ZSize_g                : positive := 4;
        DynamicRange_g         : positive := 16;
        SignedSamples_g        : boolean  := false;
        EncodingOrder_g        : string   := "BI";
        SubFrameDepth_g        : positive := 4;
        PredictionBands_g      : natural  := 3;
        PredictionMode_g       : string   := "FULL";
        LocalSum_g             : string   := "WIDE_NEIGHBOR";
        RegisterSize_g         : positive := 64;
        WeightResolution_g     : positive := 13;
        WeightUpdateInterval_g : positive := 6;
        WeightUpdateVmin_g     : integer  := -1;
        WeightUpdateVmax_g     : integer  := 3;
        WeightExpOffsetsUsed_g : boolean  := false;
        WeightExpOffsets_g     : string   := "0";
        CustomWeights_g        : boolean  := false;
        WeightInitResolution_g : natural  := 0;
        WeightInitValues_g     : string   := "0";
        Fidelity_g             : string   := "LOSSLESS";
        PeriodicUpdate_g       : boolean  := false;
        UpdatePeriodExp_g      : natural  := 0;
        AbsBandDependent_g     : boolean  := false;
        AbsErrorLimits_g       : string   := "0";
        RelBandDependent_g     : boolean  := false;
        RelErrorLimits_g       : string   := "0";
        SampleRepResolution_g  : natural  := 0;
        Damping_g              : string   := "0";
        Offset_g               : string   := "0";
        -- Speculative weight loop where it applies
        Speculation_g          : boolean  := true;
        -- Runtime configuration (test_runtime): the images of tb/golden/<config>/runtime.txt; expected
        -- acceptance cycles of the first sample of every image relative to the first (throughput model)
        RuntimeConfig_g        : boolean  := false;
        RtImages_g             : natural  := 0;
        ExpStarts_g            : string   := ""
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_predictor_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant OutW_c      : positive := maximum(DynamicRange_g, 16);
    constant ZW_c        : positive := log2ceil(ZSize_g + 1);
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
    signal Out_Data  : std_logic_vector(OutW_c - 1 downto 0);
    signal Out_Kind  : std_logic_vector(1 downto 0);
    signal Out_Band  : std_logic_vector(ZW_c - 1 downto 0);
    signal Out_First : std_logic;
    signal Out_Init  : std_logic;
    signal Out_Last  : std_logic;
    signal Ecc_Sec   : std_logic;
    signal Ecc_Ded   : std_logic;

    signal SinkDone : boolean := false;

    -- Runtime configuration: configuration inputs, take pulse, acceptance cycle of the first sample of every
    -- image
    signal Cfg_XSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Cfg_YSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Cfg_ZSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Cfg_AbsLimit : std_logic_vector(15 downto 0) := (others => '0');
    signal Cfg_RelLimit : std_logic_vector(15 downto 0) := (others => '0');
    signal Cfg_Take     : std_logic;
    signal Takes        : natural                       := 0;

    type NatArr_t is array (natural range <>) of natural;

    signal StartCyc : NatArr_t(0 to 63) := (others => 0);

    -- Values of image k of runtime.txt: driven NX, NY, NZ, absolute and relative limit, then the values taken
    impure function rtValues (k : natural) return integer_vector is
        variable Line_v : line;
        variable V_v    : integer_vector(0 to 9);

        file Rt_f : text;
    begin
        file_open(Rt_f, GoldenDir_g & "/runtime.txt", read_mode);

        for i in 0 to k loop
            readline(Rt_f, Line_v);
        end loop;

        for i in V_v'range loop
            read(Line_v, V_v(i));
        end loop;

        file_close(Rt_f);
        return V_v;
    end function;

    function twoDigits (k : natural) return string is
    begin
        if k < 10 then
            return "0" & to_string(k);
        end if;
        return to_string(k);
    end function;

    -- Throughput: cycles of the first and the last accepted sample, number of samples
    signal RateFirst : natural := 0;
    signal RateLast  : natural := 0;
    signal RateCount : natural := 0;
    signal OutFirstC : natural := 0;
    signal OutLastC  : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_predictor
        generic map (
            XSize_g                => XSize_g,
            YSize_g                => YSize_g,
            ZSize_g                => ZSize_g,
            DynamicRange_g         => DynamicRange_g,
            SignedSamples_g        => SignedSamples_g,
            EncodingOrder_g        => EncodingOrder_g,
            SubFrameDepth_g        => SubFrameDepth_g,
            PredictionBands_g      => PredictionBands_g,
            PredictionMode_g       => PredictionMode_g,
            LocalSum_g             => LocalSum_g,
            RegisterSize_g         => RegisterSize_g,
            WeightResolution_g     => WeightResolution_g,
            WeightUpdateInterval_g => WeightUpdateInterval_g,
            WeightUpdateVmin_g     => WeightUpdateVmin_g,
            WeightUpdateVmax_g     => WeightUpdateVmax_g,
            WeightExpOffsetsUsed_g => WeightExpOffsetsUsed_g,
            WeightExpOffsets_g     => parseIntVec(WeightExpOffsets_g),
            CustomWeights_g        => CustomWeights_g,
            WeightInitResolution_g => WeightInitResolution_g,
            WeightInitValues_g     => parseIntVec(WeightInitValues_g),
            Fidelity_g             => Fidelity_g,
            PeriodicUpdate_g       => PeriodicUpdate_g,
            UpdatePeriodExp_g      => UpdatePeriodExp_g,
            AbsBandDependent_g     => AbsBandDependent_g,
            AbsErrorLimits_g       => parseIntVec(AbsErrorLimits_g),
            RelBandDependent_g     => RelBandDependent_g,
            RelErrorLimits_g       => parseIntVec(RelErrorLimits_g),
            SampleRepResolution_g  => SampleRepResolution_g,
            Damping_g              => parseIntVec(Damping_g),
            Offset_g               => parseIntVec(Offset_g),
            Speculation_g          => Speculation_g,
            RuntimeConfig_g        => RuntimeConfig_g
        )
        port map (
            Clk          => Clk,
            Rst          => Rst,
            In_Valid     => In_Valid,
            In_Ready     => In_Ready,
            In_Data      => In_Data,
            Lim_Valid    => Lim_Valid,
            Lim_Ready    => Lim_Ready,
            Lim_Data     => Lim_Data,
            Cfg_XSize    => Cfg_XSize,
            Cfg_YSize    => Cfg_YSize,
            Cfg_ZSize    => Cfg_ZSize,
            Cfg_AbsLimit => Cfg_AbsLimit,
            Cfg_RelLimit => Cfg_RelLimit,
            Cfg_Take     => Cfg_Take,
            Img_Start    => open,
            Out_Valid    => Out_Valid,
            Out_Ready    => Out_Ready,
            Out_Data     => Out_Data,
            Out_Kind     => Out_Kind,
            Out_Band     => Out_Band,
            Out_First    => Out_First,
            Out_Init     => Out_Init,
            Out_Last     => Out_Last,
            Ecc_Sec      => Ecc_Sec,
            Ecc_Ded      => Ecc_Ded
        );

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
        constant Starts_c : integer_vector := parseIntVec(ExpStarts_g & ",0");
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_golden") or run("test_runtime") then
                Rst <= '1';
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                Rst <= '0';
                wait until SinkDone;

                -- Throughput
                log(ID_SEQUENCER, "accepted " & to_string(RateCount) & " samples in " &
                    to_string(RateLast - RateFirst + 1) & " cycles");
                if ExpCycles_g > 0 then
                    check_value(RateLast - RateFirst, ExpCycles_g, ERROR,
                                "cycles between the first and the last sample (throughput model)");
                end if;
                -- Runtime configuration: one take per image, the first sample of every image in the cycle of
                -- the throughput model (image-start sequencer)
                if RuntimeConfig_g then
                    check_value(Takes, RtImages_g, ERROR, "one configuration take per image");
                    if ExpStarts_g /= "" then

                        for k in 0 to RtImages_g - 1 loop
                            check_value(StartCyc(k) - StartCyc(0), Starts_c(Starts_c'low + k), ERROR,
                                        "image " & to_string(k) & ": cycle of the first sample (throughput model)");
                        end loop;

                    end if;
                end if;
                log(ID_SEQUENCER, "output in " & to_string(OutLastC - OutFirstC + 1) & " cycles");
                if ExpOutCycles_g > 0 then
                    check_value(OutLastC - OutFirstC, ExpOutCycles_g, ERROR,
                                "cycles between the first and the last item at the output (throughput model)");
                end if;

                -- No memory error and no further output
                for i in 0 to 99 loop
                    wait until rising_edge(Clk);
                    check_value(Out_Valid, '0', ERROR, "no output after the last item");
                    check_value(Ecc_Sec or Ecc_Ded, '0', ERROR, "no memory error");
                end loop;

            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -- Image samples (little-endian 8, 16 or 32-bit containers)
    p_source : process is
        variable Byte_v  : natural;
        variable Eof_v   : boolean;
        variable Smp_v   : std_logic_vector(31 downto 0);
        variable Img_v   : natural;
        variable First_v : boolean;
        variable V_v     : integer_vector(0 to 9);

        -- Configuration inputs of image k (the values driven on the configuration inputs)
        procedure drive (k : natural) is
        begin
            V_v          := rtValues(k);
            Cfg_XSize    <= std_logic_vector(to_unsigned(V_v(0), 17));
            Cfg_YSize    <= std_logic_vector(to_unsigned(V_v(1), 17));
            Cfg_ZSize    <= std_logic_vector(to_unsigned(V_v(2), 17));
            Cfg_AbsLimit <= std_logic_vector(to_unsigned(V_v(3), 16));
            Cfg_RelLimit <= std_logic_vector(to_unsigned(V_v(4), 16));
        end procedure;

        file Img_f : ByteFile_t;
    begin
        Img_v := 0;
        if RuntimeConfig_g then
            file_open(Img_f, GoldenDir_g & "/image_00.raw", read_mode);
            drive(0);
        else
            file_open(Img_f, GoldenDir_g & "/image.raw", read_mode);
        end if;
        First_v := true;
        wait until Rst = '0';

        loop
            Smp_v := (others => '0');

            for b in 0 to Bytes_c - 1 loop
                readByte(Img_f, Byte_v, Eof_v);
                Smp_v(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(Byte_v, 8));
            end loop;

            -- Runtime configuration: the next image with its configuration
            if Eof_v and RuntimeConfig_g and Img_v + 1 < RtImages_g then
                file_close(Img_f);
                Img_v   := Img_v + 1;
                First_v := true;
                drive(Img_v);
                file_open(Img_f, GoldenDir_g & "/image_" & twoDigits(Img_v) & ".raw", read_mode);
                next;
            end if;
            exit when Eof_v;

            while random(0, 99) < InGapPct_g loop
                wait until rising_edge(Clk);
            end loop;

            In_Valid <= '1';
            In_Data  <= Smp_v(DynamicRange_g - 1 downto 0);
            wait until rising_edge(Clk) and In_Ready = '1';
            In_Valid <= '0';
            if RuntimeConfig_g then
                -- The configuration is taken with the first sample of the image only; afterwards the inputs
                -- already carry the values of the next image (they must not change the image in progress)
                check_value(Cfg_Take, toSl(First_v), ERROR, "image " & to_string(Img_v) & ": configuration taken " &
                            "with the first sample only");
                if First_v and Img_v + 1 < RtImages_g then
                    drive(Img_v + 1);
                end if;
                First_v := false;
            end if;
        end loop;

        file_close(Img_f);
        wait;
    end process;

    -- Throughput: cycle of the first and the last accepted sample and output item
    p_rate : process is
        variable Cycle_v  : natural := 0;
        variable Count_v  : natural := 0;
        variable OutCnt_v : natural := 0;
    begin
        wait until Rst = '0';

        loop
            wait until rising_edge(Clk);
            if Out_Valid = '1' and Out_Ready = '1' then
                if OutCnt_v = 0 then
                    OutFirstC <= Cycle_v;
                end if;
                OutLastC <= Cycle_v;
                OutCnt_v := OutCnt_v + 1;
            end if;
            if Cfg_Take = '1' then
                StartCyc(Takes) <= Cycle_v;
                Takes           <= Takes + 1;
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
        end loop;

    end process;

    -- Periodic error limit values (16-bit big-endian)
    p_limits : process is
        variable Hi_v  : natural;
        variable Lo_v  : natural;
        variable Eof_v : boolean;

        file Lim_f : ByteFile_t;
    begin
        if not Periodic_c then
            wait;
        end if;
        file_open(Lim_f, GoldenDir_g & "/error_limits.bin", read_mode);
        wait until Rst = '0';

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
        wait;
    end process;

    -- Entropy coder input sequence of the reference model: "S <z> <t> <delta>" or "L <a|r> <value>"
    p_sink : process is
        variable Line_v  : line;
        variable Kind_v  : character;
        variable Sep_v   : character;
        variable Z_v     : integer;
        variable T_v     : integer;
        variable Val_v   : std_logic_vector(31 downto 0);
        variable Items_v : natural := 0;
        variable Last_v  : boolean;
        variable Img_v   : natural := 0;

        file Ref_f : text;
    begin
        if RuntimeConfig_g then
            file_open(Ref_f, GoldenDir_g & "/delta_00.txt", read_mode);
        else
            file_open(Ref_f, GoldenDir_g & "/delta.txt", read_mode);
        end if;
        wait until Rst = '0';

        loop
            -- Runtime configuration: the items of the next image
            if endfile(Ref_f) and RuntimeConfig_g and Img_v + 1 < RtImages_g then
                file_close(Ref_f);
                log(ID_SEQUENCER, "image " & to_string(Img_v) & " checked (" & to_string(Items_v) & " items so far)");
                Img_v := Img_v + 1;
                file_open(Ref_f, GoldenDir_g & "/delta_" & twoDigits(Img_v) & ".txt", read_mode);
            end if;
            exit when endfile(Ref_f);
            readline(Ref_f, Line_v);
            read(Line_v, Kind_v);
            Last_v := endfile(Ref_f);

            -- Wait for the next item
            while random(0, 99) < OutStallPct_g loop
                Out_Ready <= '0';
                wait until rising_edge(Clk);
            end loop;

            Out_Ready <= '1';
            wait until rising_edge(Clk) and Out_Valid = '1';
            Out_Ready <= '0';
            if Kind_v = 'S' then
                read(Line_v, Z_v);
                read(Line_v, T_v);
                hread(Line_v, Val_v);
                check_value(Out_Kind, ItemSample_c, ERROR, "item " & to_string(Items_v) & ": sample");
                check_value(to_integer(unsigned(Out_Band)), Z_v, ERROR, "item " & to_string(Items_v) & ": band");
                check_value(Out_First, toSl(T_v = 0), ERROR, "item " & to_string(Items_v) & ": first flag");
                check_value(Out_Init, toSl(T_v = 1), ERROR, "item " & to_string(Items_v) & ": init flag");
                check_value(Out_Data, Val_v(OutW_c - 1 downto 0), ERROR,
                            "item " & to_string(Items_v) & ": mapped quantizer index of z=" & to_string(Z_v) &
                            " t=" & to_string(T_v));
            else
                read(Line_v, Sep_v);
                read(Line_v, Sep_v);
                hread(Line_v, Val_v);
                if Sep_v = 'a' then
                    check_value(Out_Kind, ItemAbsLimit_c, ERROR, "item " & to_string(Items_v) & ": absolute limit");
                else
                    check_value(Out_Kind, ItemRelLimit_c, ERROR, "item " & to_string(Items_v) & ": relative limit");
                end if;
                check_value(Out_Data, Val_v(OutW_c - 1 downto 0), ERROR, "item " & to_string(Items_v) & ": limit");
            end if;
            check_value(Out_Last, toSl(Last_v), ERROR, "image " & to_string(Img_v) & " item " & to_string(Items_v) &
                        ": last flag");
            Items_v := Items_v + 1;
        end loop;

        file_close(Ref_f);
        log(ID_SEQUENCER, "checked " & to_string(Items_v) & " items");
        SinkDone <= true;
        wait;
    end process;

end architecture;
