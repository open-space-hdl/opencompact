---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Shared verification package of OpenCompact: conversion of the string generics of the testbenches
-- (per-band tables, supplementary information tables), access to the binary files of the golden
-- data (tb/golden) and the test end check.
--
-- Documentation: docs/architecture.md (verification architecture)

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

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocp_tb_pkg is

    -- Binary files (one character per byte)
    type ByteFile_t is file of character;

    -- Comma-separated list of integers ("1,-2,3") as integer_vector
    function parseIntVec (s : string) return integer_vector;

    -- Hexadecimal string ("0A1B") as std_logic_vector (first digit in the most significant bits)
    function hexToSlv (s : string) return std_logic_vector;

    -- Reads the next byte of a binary file; eof is true when the file has no further byte
    procedure readByte (
        file f : ByteFile_t;
        value  : out natural;
        eof    : out boolean);

    -- Ends a test: fails when UVVM reports an unexpected alert or misses an expected one
    procedure ocpTestEnd (signal runner : inout runner_sync_t);

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocp_tb_pkg is

    function parseIntVec (s : string) return integer_vector is
        variable Count_v : natural := 1;
        variable Res_v   : integer_vector(0 to s'length);
        variable Idx_v   : natural := 0;
        variable Val_v   : integer := 0;
        variable Neg_v   : boolean := false;
        variable Any_v   : boolean := false;
    begin

        for i in s'range loop
            if s(i) = ',' then
                Count_v := Count_v + 1;
            end if;
        end loop;

        for i in s'range loop
            if s(i) = ',' then
                Res_v(Idx_v) := Val_v;
                if Neg_v then
                    Res_v(Idx_v) := -Val_v;
                end if;
                Idx_v := Idx_v + 1;
                Val_v := 0;
                Neg_v := false;
            elsif s(i) = '-' then
                Neg_v := true;
            elsif s(i) >= '0' and s(i) <= '9' then
                Val_v := Val_v * 10 + (character'pos(s(i)) - character'pos('0'));
                Any_v := true;
            end if;
        end loop;

        Res_v(Idx_v) := Val_v;
        if Neg_v then
            Res_v(Idx_v) := -Val_v;
        end if;
        if not Any_v then
            return (0 => 0);
        end if;
        return Res_v(0 to Count_v - 1);
    end function;

    function hexToSlv (s : string) return std_logic_vector is
        variable Res_v : std_logic_vector(4 * s'length - 1 downto 0);
        variable Nib_v : natural;
        variable Pos_v : natural := 4 * s'length;
    begin

        for i in s'range loop

            case s(i) is
                when '0' to '9' =>
                    Nib_v := character'pos(s(i)) - character'pos('0');
                when 'A' to 'F' =>
                    Nib_v := character'pos(s(i)) - character'pos('A') + 10;
                when 'a' to 'f' =>
                    Nib_v := character'pos(s(i)) - character'pos('a') + 10;
                when others =>
                    Nib_v := 0;
            end case;

            Pos_v                         := Pos_v - 4;
            Res_v(Pos_v + 3 downto Pos_v) := std_logic_vector(to_unsigned(Nib_v, 4));
        end loop;

        return Res_v;
    end function;

    procedure readByte (
        file f : ByteFile_t;
        value  : out natural;
        eof    : out boolean) is
        variable Char_v : character;
    begin
        if endfile(f) then
            value := 0;
            eof   := true;
        else
            read(f, Char_v);
            value := character'pos(Char_v);
            eof   := false;
        end if;
    end procedure;

    procedure ocpTestEnd (signal runner : inout runner_sync_t) is
    begin
        report_alert_counters(FINAL);
        if shared_uvvm_status.mismatch_on_expected_simulation_warnings_or_worse /= 0 then
            alert(TB_ERROR, "UVVM alert counters do not match the expected alerts", "ocpTestEnd");
        end if;
        test_runner_cleanup(runner);
    end procedure;

end package body;
