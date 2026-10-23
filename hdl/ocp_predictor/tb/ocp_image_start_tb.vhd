---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocp_image_start, the image-start sequencer of the predictor (TC-PR-40):
--
-- * test_sweep: for every NX from 1 to XMax_g, every NZ from 1 to ZMax_g (every M from 1 to the
--   sub-frame interleaving depth, and M < NZ beyond it) and NY in {1, 2, 3, 64}, and for the
--   points of Extra_g, the issue conditions of the sequencer equal those that the elaboration
--   computes for constant dimensions (issueDist of ocp_pkg), and Done follows Start after
--   imageStartCycles clock cycles for every input
--
-- Documentation: hdl/ocp_predictor/docs/verification_plan.md

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
entity ocp_image_start_tb is
    generic (
        runner_cfg      : string;
        -- Configuration of the predictor (ocp_predictor: the latencies and flags of a configuration)
        Bsq_g           : boolean  := false;
        SubFrameDepth_g : positive := 4;
        PredBands_g     : natural  := 3;
        RepIsSample_g   : boolean  := true;
        WUsed_g         : boolean  := true;
        CrossRep_g      : boolean  := false;
        LWin_g          : natural  := 4;
        LRep_g          : natural  := 20;
        LDw_g           : natural  := 5;
        -- Sweep: NX from 1 to XMax_g, NZ from 1 to ZMax_g; further points NX, NY, NZ (in groups of three)
        XMax_g          : positive := 64;
        ZMax_g          : positive := 8;
        Extra_g         : string   := "65536,65536,65536"
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocp_image_start_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Cycles_c    : positive := imageStartCycles(LRep_g, LDw_g);

    signal Clk         : std_logic                     := '0';
    signal Rst         : std_logic                     := '1';
    signal Start       : std_logic                     := '0';
    signal In_XSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal In_YSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal In_ZSize    : std_logic_vector(16 downto 0) := (others => '0');
    signal Done        : std_logic;
    signal Out_M       : std_logic_vector(16 downto 0);
    signal Out_Gap1    : std_logic;
    signal Out_RunRows : std_logic;
    signal Out_LFix    : std_logic_vector(7 downto 0);
    signal Out_LCross  : std_logic_vector(7 downto 0);

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity work.ocp_image_start
        generic map (
            Bsq_g           => Bsq_g,
            SubFrameDepth_g => SubFrameDepth_g,
            PredBands_g     => PredBands_g,
            RepIsSample_g   => RepIsSample_g,
            WUsed_g         => WUsed_g,
            CrossRep_g      => CrossRep_g,
            LWin_g          => LWin_g,
            LRep_g          => LRep_g,
            LDw_g           => LDw_g
        )
        port map (
            Clk         => Clk,
            Rst         => Rst,
            Start       => Start,
            In_XSize    => In_XSize,
            In_YSize    => In_YSize,
            In_ZSize    => In_ZSize,
            Done        => Done,
            Out_M       => Out_M,
            Out_Gap1    => Out_Gap1,
            Out_RunRows => Out_RunRows,
            Out_LFix    => Out_LFix,
            Out_LCross  => Out_LCross
        );

    Clk <= not Clk after ClkPeriod_c / 2;

    -----------------------------------------------------------------------------------------------
    -- Test sequencer
    -----------------------------------------------------------------------------------------------
    p_main : process is
        variable Points_v : natural := 0;

        -- One image start: the results and the number of cycles against the elaboration function
        procedure check (nx : positive; ny : positive; nz : positive) is
            constant Exp_c  : IssueDist_r := issueDist(Bsq_g, SubFrameDepth_g, nx, ny, nz, PredBands_g,
                                                       RepIsSample_g, WUsed_g, CrossRep_g, LWin_g, LRep_g, LDw_g);
            constant What_c : string      := "NX " & to_string(nx) & ", NY " & to_string(ny) & ", NZ " &
                                             to_string(nz) & ": ";
            variable Cyc_v  : natural     := 0;
        begin
            In_XSize <= std_logic_vector(to_unsigned(nx, 17));
            In_YSize <= std_logic_vector(to_unsigned(ny, 17));
            In_ZSize <= std_logic_vector(to_unsigned(nz, 17));
            Start    <= '1';
            wait until rising_edge(Clk);
            Start    <= '0';
            -- Random inputs after Start: the sequencer uses the values taken with Start
            In_XSize <= std_logic_vector(to_unsigned(random(1, 65536), 17));
            In_ZSize <= std_logic_vector(to_unsigned(random(1, 65536), 17));

            -- Cyc_v: the clock cycle after the cycle of Start whose values are read (the registered outputs
            -- change after the clock edge)
            loop
                exit when Done = '1' or Cyc_v > 2 * Cycles_c;
                wait until rising_edge(Clk);
                Cyc_v := Cyc_v + 1;
            end loop;

            check_value(Cyc_v, Cycles_c, ERROR, What_c & "cycles from Start to Done");
            check_value(to_integer(unsigned(Out_M)), Exp_c.M, ERROR, What_c & "M");
            check_value(Out_Gap1, toSl(Exp_c.Gap1), ERROR, What_c & "consecutive samples of a band");
            check_value(Out_RunRows, toSl(Exp_c.RunRows), ERROR, What_c & "run of a band across rows");
            check_value(to_integer(unsigned(Out_LFix)), Exp_c.LFix, ERROR, What_c & "distance in the band");
            check_value(to_integer(unsigned(Out_LCross)), Exp_c.LCross, ERROR, What_c & "distance to the previous band");
            Points_v := Points_v + 1;

            -- Some idle cycles between the image starts
            for i in 1 to random(0, 2) loop
                wait until rising_edge(Clk);
            end loop;

        end procedure;

        constant Ny_c    : integer_vector := (1, 2, 3, 64);
        constant Extra_c : integer_vector := parseIntVec(Extra_g);
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop
            if run("test_sweep") then
                Rst <= '1';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                Rst <= '0';
                wait until rising_edge(Clk);

                for ny in Ny_c'range loop

                    for nz in 1 to ZMax_g loop

                        for nx in 1 to XMax_g loop
                            check(nx, Ny_c(ny), nz);
                        end loop;

                    end loop;

                end loop;

                for i in 0 to Extra_c'length / 3 - 1 loop
                    check(Extra_c(Extra_c'low + 3 * i), Extra_c(Extra_c'low + 3 * i + 1),
                          Extra_c(Extra_c'low + 3 * i + 2));
                end loop;

                log(ID_SEQUENCER, to_string(Points_v) & " image starts checked");
            end if;
        end loop;

        ocpTestEnd(runner);
    end process;

end architecture;
