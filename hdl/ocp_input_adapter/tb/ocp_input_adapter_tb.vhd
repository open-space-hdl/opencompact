---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_input_adapter: the source sends SDUs of random samples (big-endian containers of
-- ceil(D/8) bytes) with the user signal of the OpenSPP receive port (22 bits: end mark CPTP User
-- Application 1 in bits 21:14, faults in bits 12 and 13) or with the default masks (UserWidth_g 1:
-- every SDU ends an image). A reference model in the source predicts every sample with its image
-- end and error flags and the events; the sink compares.
--
-- * test_samples: SDUs of 1 to 40 samples with random end marks, no fault; the user signal is random
--   on every beat but the last
-- * test_faults: faulty SDUs (bit 12, bit 13, incomplete last container) with and without end mark,
--   the discard of the rest of the image (also of faulty and of single-sample SDUs), SDUs of one
--   sample and of one byte, then a random sequence of SDUs with faults
-- * test_reset: resets while an SDU is in the converter and while SDUs are discarded, each followed
--   by a correct sequence
-- * test_rate: without back pressure the samples leave at the byte rate of the source, with at most
--   one cycle without a sample between two SDUs
--
-- Documentation: hdl/ocp_input_adapter/docs/verification_plan.md

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
entity ocp_input_adapter_tb is
    generic (
        runner_cfg     : string;
        InWidth_g      : positive := 128;
        DynamicRange_g : positive := 16;
        -- 22: user signal of the OpenSPP receive port; 1: default masks (every SDU ends an image)
        UserWidth_g    : positive := 22;
        -- Back pressure: probability (percent) of an idle cycle of the source and of a stall of the sink
        InGapPct_g     : natural  := 0;
        OutStallPct_g  : natural  := 0
    );
end entity;

architecture sim of ocp_input_adapter_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := (DynamicRange_g + 7) / 8;
    constant Lanes_c     : positive := InWidth_g / 8;
    constant Spp_c       : boolean  := UserWidth_g = 22;

    subtype User_t is std_logic_vector(UserWidth_g - 1 downto 0);

    function userConst (spp : std_logic_vector) return User_t is
    begin
        if Spp_c then
            return spp;
        end if;
        return (others => '0');
    end function;

    constant LastMask_c  : User_t := userConst(22x"3FC000");
    constant LastValue_c : User_t := userConst(22x"004000");
    constant ErrorMask_c : User_t := userConst(22x"003000");

    -- Kinds of fault of an SDU
    constant NoFault_c : natural := 0;
    constant Dli_c     : natural := 1;
    constant Ded_c     : natural := 2;
    constant Length_c  : natural := 3;

    -- Expected samples (circular buffer written by the source, read by the sink)
    constant ExpDepth_c : positive := 4096;

    type ExpEntry_r is record
        Data  : std_logic_vector(DynamicRange_g - 1 downto 0);
        Last  : std_logic;
        Error : std_logic;
    end record;

    type ExpArr_t is array (0 to ExpDepth_c - 1) of ExpEntry_r;

    signal Clk             : std_logic                                := '0';
    signal Rst             : std_logic                                := '1';
    signal In_Valid        : std_logic                                := '0';
    signal In_Ready        : std_logic;
    signal In_Data         : std_logic_vector(InWidth_g - 1 downto 0) := (others => '0');
    signal In_Keep         : std_logic_vector(Lanes_c - 1 downto 0)   := (others => '0');
    signal In_Last         : std_logic                                := '0';
    signal In_User         : User_t                                   := (others => '0');
    signal Out_Valid       : std_logic;
    signal Out_Ready       : std_logic                                := '0';
    signal Out_Data        : std_logic_vector(DynamicRange_g - 1 downto 0);
    signal Out_Last        : std_logic;
    signal Out_Error       : std_logic;
    signal Ev_SduError     : std_logic;
    signal Ev_SduDiscarded : std_logic;

    signal Exp      : ExpArr_t;
    signal ExpCount : natural := 0;      -- entries written
    signal GotCount : natural := 0;      -- samples checked

    -- Expected and observed events since the last clear
    signal ExpErrors  : natural := 0;
    signal ExpDiscard : natural := 0;
    signal EvErrors   : natural := 0;
    signal EvDiscard  : natural := 0;
    signal EvClear    : boolean := false;

    -- Cycles of the first and the last sample at the output since the last clear
    signal FirstCycle : natural := 0;
    signal LastCycle  : natural := 0;

    -- Sink: probability of a stall (changed by test_rate)
    signal StallPct : natural := OutStallPct_g;

begin

    i_dut : entity work.ocp_input_adapter
        generic map (
            InWidth_g       => InWidth_g,
            DynamicRange_g  => DynamicRange_g,
            UserWidth_g     => UserWidth_g,
            UserLastMask_g  => LastMask_c,
            UserLastValue_g => LastValue_c,
            UserErrorMask_g => ErrorMask_c
        )
        port map (
            Clk             => Clk,
            Rst             => Rst,
            In_Valid        => In_Valid,
            In_Ready        => In_Ready,
            In_Data         => In_Data,
            In_Keep         => In_Keep,
            In_Last         => In_Last,
            In_User         => In_User,
            Out_Valid       => Out_Valid,
            Out_Ready       => Out_Ready,
            Out_Data        => Out_Data,
            Out_Last        => Out_Last,
            Out_Error       => Out_Error,
            Ev_SduError     => Ev_SduError,
            Ev_SduDiscarded => Ev_SduDiscarded
        );

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Sequencer and source with the reference model
    -----------------------------------------------------------------------------------------------
    p_main : process is
        variable Discard_v : boolean := false;
        variable Count_v   : natural := 0;
        variable NErr_v    : natural := 0;
        variable NDisc_v   : natural := 0;
        variable Abort_v   : boolean := false;

        -- User signal of the last beat of an SDU with the given end mark and fault
        impure function userOf (mark : boolean; fault : natural) return User_t is
            variable U_v : User_t;
        begin
            U_v := std_logic_vector(to_unsigned(random(0, 2 ** minimum(UserWidth_g, 30) - 1), UserWidth_g));
            if Spp_c then
                if mark then
                    U_v(21 downto 14) := x"01";
                elsif random(0, 1) = 0 then
                    U_v(21 downto 14) := x"00";
                else
                    U_v(21 downto 14) := std_logic_vector(to_unsigned(random(2, 255), 8));
                end if;
                U_v(12) := toSl(fault = Dli_c);
                U_v(13) := toSl(fault = Ded_c);
            end if;
            return U_v;
        end function;

        -- One SDU of n samples (a fault Length_c removes 1 to Bytes_c - 1 bytes of the last container);
        -- stops at a reset (Abort_v)
        procedure sdu (n : positive; mark_in : boolean; fault_in : natural) is
            variable Fault_v  : natural;
            variable Mark_v   : boolean;
            variable User_v   : User_t;
            variable NBytes_v : natural;
            variable Smp_v    : std_logic_vector(8 * Bytes_c - 1 downto 0);
            variable Bytes_v  : std_logic_vector(8 * Bytes_c * n - 1 downto 0);
            variable Beat_v   : natural;
            variable Lane_v   : natural;
            variable E_v      : ExpEntry_r;
            variable Faulty_v : boolean;
        begin
            Fault_v := fault_in;
            if Fault_v = Length_c and Bytes_c = 1 then
                Fault_v := Ded_c;
            end if;
            if not Spp_c and (Fault_v = Dli_c or Fault_v = Ded_c) then
                Fault_v := NoFault_c;
            end if;
            User_v   := userOf(mark_in, Fault_v);
            Mark_v   := (User_v and LastMask_c) = LastValue_c;
            NBytes_v := Bytes_c * n;
            if Fault_v = Length_c then
                NBytes_v := NBytes_v - random(1, Bytes_c - 1);
            end if;
            Faulty_v := Fault_v /= NoFault_c;

            -- Samples: random values in big-endian containers (bytes beyond D random as well)
            for s in 0 to n - 1 loop
                Smp_v := std_logic_vector(to_unsigned(random(0, 2 ** minimum(8 * Bytes_c, 30) - 1), 8 * Bytes_c));
                if 8 * Bytes_c > 30 then
                    Smp_v(8 * Bytes_c - 1 downto 30) := std_logic_vector(to_unsigned(random(0, 3), 8 * Bytes_c - 30));
                end if;
                Bytes_v(8 * Bytes_c * (n - s) - 1 downto 8 * Bytes_c * (n - 1 - s)) := Smp_v;
            end loop;

            -- Reference model
            if Discard_v then
                NDisc_v := NDisc_v + 1;
                if Mark_v then
                    Discard_v := false;
                end if;
            else

                for s in 0 to (NBytes_v + Bytes_c - 1) / Bytes_c - 1 loop
                    Smp_v := Bytes_v(8 * Bytes_c * (n - s) - 1 downto 8 * Bytes_c * (n - 1 - s));

                    -- Missing bytes of an incomplete last container are zero
                    for b in 0 to Bytes_c - 1 loop
                        if s * Bytes_c + b >= NBytes_v then
                            Smp_v(8 * (Bytes_c - 1 - b) + 7 downto 8 * (Bytes_c - 1 - b)) := (others => '0');
                        end if;
                    end loop;

                    E_v.Data                    := Smp_v(DynamicRange_g - 1 downto 0);
                    E_v.Last                    := toSl((s + 1) * Bytes_c >= NBytes_v and (Mark_v or Faulty_v));
                    E_v.Error                   := toSl((s + 1) * Bytes_c >= NBytes_v and Faulty_v);
                    Exp(Count_v mod ExpDepth_c) <= E_v;
                    Count_v                     := Count_v + 1;
                end loop;

                ExpCount <= Count_v;
                if Faulty_v then
                    NErr_v := NErr_v + 1;
                    if not Mark_v then
                        Discard_v := true;
                    end if;
                end if;
            end if;
            ExpErrors  <= NErr_v;
            ExpDiscard <= NDisc_v;

            -- Beats: byte k of the SDU in lane k mod Lanes_c of beat k / Lanes_c
            Beat_v := 0;

            while Beat_v * Lanes_c < NBytes_v loop

                while random(0, 99) < InGapPct_g and Rst = '0' loop
                    In_Valid <= '0';
                    wait until rising_edge(Clk);
                end loop;

                for l in 0 to Lanes_c - 1 loop
                    Lane_v := Beat_v * Lanes_c + l;
                    if Lane_v < NBytes_v then
                        In_Data(8 * l + 7 downto 8 * l) <= Bytes_v(8 * (Bytes_c * n - Lane_v) - 1 downto
                                                                   8 * (Bytes_c * n - Lane_v - 1));
                        In_Keep(l)                      <= '1';
                    else
                        In_Data(8 * l + 7 downto 8 * l) <= std_logic_vector(to_unsigned(random(0, 255), 8));
                        In_Keep(l)                      <= '0';
                    end if;
                end loop;

                In_Valid <= '1';
                In_Last  <= toSl((Beat_v + 1) * Lanes_c >= NBytes_v);
                if (Beat_v + 1) * Lanes_c >= NBytes_v then
                    In_User <= User_v;
                else
                    -- Only the last beat carries a valid user signal (OpenSPP: error bit valid with TLast)
                    In_User <= userOf(random(0, 1) = 1, random(0, 2));
                end if;

                loop
                    wait until rising_edge(Clk);
                    exit when In_Ready = '1' or Rst = '1';
                end loop;

                Abort_v := Rst = '1';
                exit when Abort_v;
                Beat_v  := Beat_v + 1;
            end loop;

            In_Valid <= '0';
            In_Last  <= '0';
        end procedure;

        -- Waits until the sink has checked every expected sample, then compares the events
        procedure drain is
            variable Cycles_v : natural := 0;
        begin

            -- Watchdog: every expected sample within a time limit
            while GotCount /= Count_v loop
                wait until rising_edge(Clk);
                Cycles_v := Cycles_v + 1;
                if Cycles_v > 1000000 then
                    alert(ERROR, "every expected sample within the time limit");
                    exit;
                end if;
            end loop;

            for i in 1 to 4 loop
                wait until rising_edge(Clk);
            end loop;

            check_value(EvErrors, ExpErrors, ERROR, "faulty SDU events");
            check_value(EvDiscard, ExpDiscard, ERROR, "discarded SDU events");
        end procedure;

        -- Reset of the DUT and of the reference model
        procedure reset is
        begin
            Rst        <= '1';
            In_Valid   <= '0';
            wait until rising_edge(Clk);
            wait until rising_edge(Clk);
            Discard_v  := false;
            NErr_v     := 0;
            NDisc_v    := 0;
            ExpErrors  <= 0;
            ExpDiscard <= 0;
            -- The sink drops the samples that the reset aborted
            EvClear <= true;
            wait until rising_edge(Clk);
            EvClear <= false;
            Rst     <= '0';
            wait until rising_edge(Clk);
        end procedure;

        -- Random sequence of SDUs
        procedure randomSdus (count : positive; faults : boolean) is
            variable F_v : natural;
        begin

            for i in 1 to count loop
                F_v := NoFault_c;
                if faults and random(0, 3) = 0 then
                    F_v := random(1, 3);
                end if;
                sdu(random(1, 40), random(0, 3) = 0, F_v);
            end loop;

            -- Ends with the end of an image
            sdu(random(1, 8), true, NoFault_c);
        end procedure;

        variable Cycles_v : natural;
        variable Smps_v   : natural;
        variable Sdus_v   : natural;
        variable Beats_v  : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            reset;

            if run("test_samples") then
                randomSdus(60, false);
                drain;

            elsif run("test_faults") then
                -- A faulty SDU without end mark: the rest of the image is discarded, also a faulty SDU in it
                sdu(5, false, NoFault_c);
                sdu(7, false, Dli_c);
                sdu(3, false, NoFault_c);
                sdu(4, false, Ded_c);
                sdu(6, true, NoFault_c);
                -- A faulty SDU with end mark: nothing is discarded
                sdu(9, false, NoFault_c);
                sdu(8, true, Ded_c);
                sdu(2, true, NoFault_c);
                -- Incomplete last container without and with end mark; a discarded single-sample SDU
                sdu(6, false, Length_c);
                sdu(1, false, NoFault_c);
                sdu(1, true, Dli_c);
                sdu(3, true, Length_c);
                -- Single sample and single byte SDUs
                sdu(1, true, NoFault_c);
                sdu(1, false, NoFault_c);
                sdu(1, true, Length_c);
                sdu(1, false, Length_c);
                sdu(2, true, NoFault_c);
                drain;
                -- Random faults
                randomSdus(80, true);
                drain;

            elsif run("test_reset") then

                for i in 1 to 6 loop
                    -- A reset while an SDU is in the converter, or while SDUs are discarded
                    if i mod 2 = 1 then
                        sdu(20, false, NoFault_c);
                    else
                        sdu(3, false, Ded_c);
                        sdu(20, false, NoFault_c);
                    end if;
                    reset;
                    randomSdus(4, false);
                    drain;
                end loop;

            elsif run("test_rate") then
                StallPct <= 0;
                EvClear  <= true;
                wait until rising_edge(Clk);
                EvClear  <= false;
                Smps_v   := 0;
                Sdus_v   := 0;
                Beats_v  := 0;

                for i in 1 to 20 loop
                    Smps_v  := Smps_v + 10 + i;
                    Sdus_v  := Sdus_v + 1;
                    Beats_v := Beats_v + ((10 + i) * Bytes_c + Lanes_c - 1) / Lanes_c;
                    sdu(10 + i, i mod 5 = 0, NoFault_c);
                end loop;

                drain;
                Cycles_v := LastCycle - FirstCycle + 1;
                log(ID_SEQUENCER, to_string(Smps_v) & " samples in " & to_string(Cycles_v) & " cycles");
                -- One beat of the source per cycle, at most one sample per cycle
                check_value(Cycles_v <= maximum(Smps_v, Beats_v) + Sdus_v + 2,
                            ERROR, "samples at the byte rate of the source, one cycle between SDUs");
            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Sink: compares every sample with the reference model
    -----------------------------------------------------------------------------------------------
    p_sink : process is
        variable E_v     : ExpEntry_r;
        variable Got_v   : natural := 0;
        variable Cycle_v : natural := 0;
        variable First_v : boolean := true;
    begin
        wait until rising_edge(Clk);
        Cycle_v := Cycle_v + 1;
        if Rst = '1' then
            Out_Ready <= '0';
        else
            if Out_Valid = '1' and Out_Ready = '1' then
                check_value(Got_v < ExpCount, ERROR, "sample " & to_string(Got_v) & ": expected");
                E_v := Exp(Got_v mod ExpDepth_c);
                check_value(Out_Data, E_v.Data, ERROR, "sample " & to_string(Got_v));
                check_value(Out_Last, E_v.Last, ERROR, "sample " & to_string(Got_v) & ": image end");
                check_value(Out_Error, E_v.Error, ERROR, "sample " & to_string(Got_v) & ": error flag");
                if First_v then
                    FirstCycle <= Cycle_v;
                    First_v    := false;
                end if;
                LastCycle <= Cycle_v;
                Got_v     := Got_v + 1;
                GotCount  <= Got_v;
            end if;
            Out_Ready <= toSl(random(0, 99) >= StallPct);
        end if;
        -- A reset drops the samples in flight
        if EvClear then
            Got_v    := ExpCount;
            GotCount <= Got_v;
            First_v  := true;
        end if;
    end process;

    -- Events since the last clear
    p_events : process is
    begin
        wait until rising_edge(Clk);
        if EvClear then
            EvErrors  <= 0;
            EvDiscard <= 0;
        else
            if Ev_SduError = '1' then
                EvErrors <= EvErrors + 1;
            end if;
            if Ev_SduDiscarded = '1' then
                EvDiscard <= EvDiscard + 1;
            end if;
        end if;
    end process;

end architecture;
