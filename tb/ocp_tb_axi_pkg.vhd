---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Register access of the testbenches through the AXI-Lite VVC of UVVM: write, check and read of a
-- register.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
    use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axilite;
    use bitvis_vip_axilite.td_target_support_pkg.all;
    context bitvis_vip_axilite.vvc_context;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocp_tb_axi_pkg is

    constant AxiAddrBits_c : positive := 8;

    procedure regWrite (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0));

    procedure regCheck (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0);
        msg         : string);

    procedure regRead (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : out std_logic_vector(31 downto 0));

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocp_tb_axi_pkg is

    procedure regWrite (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0)) is
    begin
        axilite_write(vvct, idx, to_unsigned(addr, AxiAddrBits_c), data,
                      "write 0x" & to_hstring(to_unsigned(addr, AxiAddrBits_c)));
        await_completion(vvct, idx, 100 us);
    end procedure;

    procedure regCheck (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0);
        msg         : string) is
    begin
        axilite_check(vvct, idx, to_unsigned(addr, AxiAddrBits_c), data, msg);
        await_completion(vvct, idx, 100 us);
    end procedure;

    procedure regRead (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : out std_logic_vector(31 downto 0)) is
        variable Cmd_v  : natural;
        variable Data_v : bitvis_vip_axilite.vvc_cmd_pkg.t_vvc_result;
        variable Ok_v   : boolean;
    begin
        axilite_read(vvct, idx, to_unsigned(addr, AxiAddrBits_c), "read 0x" & to_hstring(to_unsigned(addr, AxiAddrBits_c)));
        Cmd_v := get_last_received_cmd_idx(vvct, idx);
        await_completion(vvct, idx, 100 us);
        fetch_result(vvct, idx, Cmd_v, Data_v, Ok_v, "fetch read result");
        data  := Data_v(31 downto 0);
    end procedure;

end package body;
