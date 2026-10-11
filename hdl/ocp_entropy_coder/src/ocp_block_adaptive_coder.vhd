---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Block-adaptive entropy coder of CCSDS 123.0-B-2 (5.4.3.4): the adaptive entropy coder of
-- CCSDS 121.0-B-3 with the preprocessor bypassed. Blocks of J values of the entropy coder input
-- sequence are encoded with the shortest of the no-compression, second-extension, fundamental
-- sequence and split-sample options; runs of all-zeros blocks with the zero-block option.
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
entity ocp_block_adaptive_coder is
    generic (
        DynamicRange_g    : positive range 2 to 32   := 16;
        BlockSize_g       : positive                 := 16;
        RestrictedCodes_g : boolean                  := false;
        RefInterval_g     : positive range 1 to 4096 := 4096
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Entropy coder input sequence
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Data   : in    std_logic_vector(maximum(DynamicRange_g, 16) - 1 downto 0);
        In_Last   : in    std_logic;
        -- Codewords
        Cw_Valid  : out   std_logic;
        Cw_Ready  : in    std_logic;
        Cw_Data   : out   std_logic_vector(CwWidth_c - 1 downto 0);
        Cw_Length : out   std_logic_vector(CwLenWidth_c - 1 downto 0);
        Cw_Last   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_block_adaptive_coder is

    constant N_c : positive := DynamicRange_g;
    constant J_c : positive := BlockSize_g;

    -- Option identifier width and largest split-sample parameter (CCSDS 121.0-B-3 table 5-1); the
    -- restricted set for n <= 2 has neither fundamental sequence nor split-sample options
    function idBits return positive is
    begin
        if RestrictedCodes_g and N_c <= 2 then
            return 1;
        elsif RestrictedCodes_g and N_c <= 4 then
            return 2;
        elsif N_c <= 8 then
            return 3;
        elsif N_c <= 16 then
            return 4;
        end if;
        return 5;
    end function;

    function kMax return integer is
    begin
        if RestrictedCodes_g and N_c <= 2 then
            return -1;
        elsif RestrictedCodes_g and N_c <= 4 then
            return 1;
        elsif N_c <= 8 then
            return 5;
        elsif N_c <= 16 then
            return 13;
        end if;
        return 29;
    end function;

    constant IdBits_c : positive := idBits;
    constant KMax_c   : integer  := kMax;
    constant KArr_c   : natural  := maximum(KMax_c, 0);
    constant LenW_c   : positive := 14;
    constant Sat_c    : natural  := 2 ** 13 - 1;

    type BufArr_t is array (0 to J_c - 1) of unsigned(N_c - 1 downto 0);
    type SumArr_t is array (0 to KArr_c) of unsigned(LenW_c - 1 downto 0);
    type Opt_t is (OptNc, OptSe, OptK);

    type Fsm_t is (
        Collect_s, Pad_s, Select_s, SelectSe_s, SelectK_s, SelectDone_s, ZeroId_s, ZeroFs_s, Id_s, Main_s,
        Lsb_s
    );

    type TwoProcess_r is record
        Fsm      : Fsm_t;
        Buf      : BufArr_t;
        Idx      : natural range 0 to J_c;
        SumK     : SumArr_t;
        SumSe    : unsigned(LenW_c - 1 downto 0);
        AllZero  : std_logic;
        Prev     : unsigned(N_c - 1 downto 0);
        Final    : std_logic;
        Opt      : Opt_t;
        K        : natural range 0 to KArr_c;
        SelK     : natural range 0 to KArr_c;
        Best     : unsigned(LenW_c + 1 downto 0);
        ZeroRun  : natural range 0 to 64;
        ZeroFs   : natural range 0 to 63;
        ZeroLast : std_logic;
        ZeroThen : std_logic;
        BlkInRef : natural range 0 to RefInterval_g - 1;
        FsRem    : natural range 0 to 2 ** 15 - 1;
        FsActive : std_logic;
        CwValid  : std_logic;
        CwData   : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLength : unsigned(CwLenWidth_c - 1 downto 0);
        CwLast   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    function satAdd (a : unsigned; b : unsigned) return unsigned is
        variable S_v : unsigned(a'length downto 0);
    begin
        S_v := resize(a, a'length + 1) + resize(b, a'length + 1);
        if S_v > Sat_c then
            return to_unsigned(Sat_c, a'length);
        end if;
        return S_v(a'length - 1 downto 0);
    end function;

    -- Second extension symbol (CCSDS 121.0-B-3 3.4.1), saturated far above any selectable length
    function secondExt (a : unsigned; b : unsigned) return unsigned is
        variable S_v : unsigned(7 downto 0);
        variable G_v : unsigned(15 downto 0);
    begin
        if a >= 128 or b >= 128 then
            return to_unsigned(Sat_c, LenW_c);
        end if;
        S_v := resize(a, 8) + resize(b, 8);
        if S_v >= 128 then
            return to_unsigned(Sat_c, LenW_c);
        end if;
        G_v := resize(shift_right(S_v * (S_v + 1), 1), 16) + resize(b, 16);
        if G_v > Sat_c then
            return to_unsigned(Sat_c, LenW_c);
        end if;
        return resize(G_v, LenW_c);
    end function;

begin

    p_comb : process (all) is
        variable v        : TwoProcess_r;
        variable Val_v    : unsigned(N_c - 1 downto 0);
        variable Len_v    : unsigned(LenW_c + 1 downto 0);
        variable SegEnd_v : boolean;
        variable Run_v    : natural range 0 to 64;
        variable Free_v   : boolean;
        variable Fs_v     : natural range 0 to 2 ** 15 - 1;
        variable Gam_v    : unsigned(LenW_c - 1 downto 0);
        variable Accept_v : boolean;
    begin
        v := r;

        if Cw_Ready = '1' then
            v.CwValid := '0';
        end if;
        Free_v := r.CwValid = '0' or Cw_Ready = '1';

        In_Ready <= '0';
        Accept_v := false;
        Val_v    := (others => '0');

        case r.Fsm is

            -- Collection of a block and of the code lengths of its options
            when Collect_s =>
                In_Ready <= '1';
                if In_Valid = '1' then
                    Val_v    := resize(unsigned(In_Data), N_c);
                    Accept_v := true;
                    if In_Last = '1' then
                        v.Final := '1';
                    end if;
                end if;

            -- Zeros appended to the last block (CCSDS 123.0-B-2 5.4.3.4.2.7)
            when Pad_s =>
                Accept_v := true;

            when Select_s =>
                -- Zero-block option for a run of all-zeros blocks inside a segment (3.5)
                SegEnd_v := (r.BlkInRef mod 64) = 63 or r.BlkInRef = RefInterval_g - 1 or r.Final = '1';
                if r.BlkInRef = RefInterval_g - 1 or r.Final = '1' then
                    v.BlkInRef := 0;
                else
                    v.BlkInRef := r.BlkInRef + 1;
                end if;
                v.Idx := 0;
                if r.AllZero = '1' then
                    Run_v := r.ZeroRun + 1;
                    if SegEnd_v then
                        if Run_v >= 5 then
                            v.ZeroFs := 4;          -- remainder of segment
                        else
                            v.ZeroFs := Run_v - 1;
                        end if;
                        v.ZeroRun  := 0;
                        v.ZeroLast := r.Final;
                        v.ZeroThen := '0';
                        v.Fsm      := ZeroId_s;
                    else
                        v.ZeroRun := Run_v;
                        v.Fsm     := Collect_s;
                    end if;
                else
                    -- Shortest single-block option, one candidate per cycle in the order of the ties of 3.7.4:
                    -- no compression, second extension, smallest k
                    v.Best := to_unsigned(N_c * J_c + IdBits_c, v.Best'length);
                    v.Opt  := OptNc;
                    v.SelK := 0;
                    v.Fsm  := SelectSe_s;
                end if;

            when SelectSe_s =>
                Len_v := resize(r.SumSe, Len_v'length) + IdBits_c + 1;
                if Len_v < r.Best then
                    v.Best := Len_v;
                    v.Opt  := OptSe;
                end if;
                if KMax_c >= 0 then
                    v.Fsm := SelectK_s;
                else
                    v.Fsm := SelectDone_s;
                end if;

            when SelectK_s =>
                Len_v := resize(r.SumK(r.SelK), Len_v'length) + J_c * (r.SelK + 1) + IdBits_c;
                if Len_v < r.Best then
                    v.Best := Len_v;
                    v.Opt  := OptK;
                    v.K    := r.SelK;
                end if;
                if r.SelK = KArr_c then
                    v.Fsm := SelectDone_s;
                else
                    v.SelK := r.SelK + 1;
                end if;

            when SelectDone_s =>
                if r.ZeroRun > 0 then
                    -- The run of all-zeros blocks before this block
                    if r.ZeroRun <= 4 then
                        v.ZeroFs := r.ZeroRun - 1;
                    else
                        v.ZeroFs := r.ZeroRun;
                    end if;
                    v.ZeroRun  := 0;
                    v.ZeroLast := '0';
                    v.ZeroThen := '1';
                    v.Fsm      := ZeroId_s;
                else
                    v.Fsm := Id_s;
                end if;

            -- Zero-block CDS: option identifier, then the fundamental sequence codeword of the run
            when ZeroId_s =>
                if Free_v then
                    v.CwValid  := '1';
                    v.CwData   := (others => '0');
                    v.CwLength := to_unsigned(IdBits_c + 1, CwLenWidth_c);
                    v.CwLast   := '0';
                    v.Fsm      := ZeroFs_s;
                end if;

            when ZeroFs_s =>
                if Free_v then
                    v.CwValid  := '1';
                    v.CwData   := (0 => '1',
                                   others => '0');
                    v.CwLength := to_unsigned(r.ZeroFs + 1, CwLenWidth_c);
                    v.CwLast   := r.ZeroLast;
                    if r.ZeroLast = '1' then
                        v.Final := '0';
                        v.Fsm   := Collect_s;
                    elsif r.ZeroThen = '1' then
                        v.Fsm := Id_s;
                    else
                        v.Fsm := Collect_s;
                    end if;
                end if;

            -- Option identifier of a single-block CDS (CCSDS 121.0-B-3 5.2)
            when Id_s =>
                if Free_v then
                    v.CwValid := '1';
                    v.CwLast  := '0';

                    case r.Opt is
                        when OptNc =>
                            v.CwData   := std_logic_vector(to_unsigned(2 ** IdBits_c - 1, CwWidth_c));
                            v.CwLength := to_unsigned(IdBits_c, CwLenWidth_c);
                        when OptSe =>
                            v.CwData   := (0 => '1',
                                           others => '0');
                            v.CwLength := to_unsigned(IdBits_c + 1, CwLenWidth_c);
                        when others =>
                            v.CwData   := std_logic_vector(to_unsigned(r.K + 1, CwWidth_c));
                            v.CwLength := to_unsigned(IdBits_c, CwLenWidth_c);
                    end case;

                    v.Idx      := 0;
                    v.FsActive := '0';
                    v.Fsm      := Main_s;
                end if;

            -- Samples (no compression), second extension symbols or fundamental sequence codewords;
            -- long fundamental sequence codewords are sent in parts of at most 64 bits
            when Main_s =>
                if Free_v then
                    v.CwValid := '1';
                    v.CwLast  := '0';
                    if r.Opt = OptNc then
                        v.CwData   := std_logic_vector(resize(r.Buf(r.Idx), CwWidth_c));
                        v.CwLength := to_unsigned(N_c, CwLenWidth_c);
                        if r.Idx = J_c - 1 then
                            v.CwLast := r.Final;
                            v.Fsm    := Collect_s;
                            v.Final  := '0';
                            v.Idx    := 0;
                        else
                            v.Idx := r.Idx + 1;
                        end if;
                    else
                        if r.FsActive = '1' then
                            Fs_v := r.FsRem;
                        elsif r.Opt = OptSe then
                            Gam_v := secondExt(r.Buf(2 * r.Idx), r.Buf(2 * r.Idx + 1));
                            Fs_v  := to_integer(Gam_v);
                        else
                            Fs_v := to_integer(shift_right(r.Buf(r.Idx), r.K)(minimum(N_c, 15) - 1 downto 0));
                        end if;
                        if Fs_v >= 64 then
                            v.CwData   := (others => '0');
                            v.CwLength := to_unsigned(64, CwLenWidth_c);
                            v.FsRem    := Fs_v - 64;
                            v.FsActive := '1';
                        else
                            v.CwData   := (0 => '1',
                                           others => '0');
                            v.CwLength := to_unsigned(Fs_v + 1, CwLenWidth_c);
                            v.FsActive := '0';
                            if (r.Opt = OptSe and r.Idx = J_c / 2 - 1) or (r.Opt = OptK and r.Idx = J_c - 1) then
                                v.Idx := 0;
                                if r.Opt = OptK and r.K > 0 then
                                    v.Fsm := Lsb_s;
                                else
                                    v.CwLast := r.Final;
                                    v.Final  := '0';
                                    v.Fsm    := Collect_s;
                                end if;
                            else
                                v.Idx := r.Idx + 1;
                            end if;
                        end if;
                    end if;
                end if;

            -- Split bits of the split-sample options
            when Lsb_s =>
                if Free_v then
                    v.CwValid  := '1';
                    v.CwData   := std_logic_vector(resize(r.Buf(r.Idx) and (shift_left(to_unsigned(1, N_c), r.K) - 1),
                                                          CwWidth_c));
                    v.CwLength := to_unsigned(r.K, CwLenWidth_c);
                    v.CwLast   := '0';
                    if r.Idx = J_c - 1 then
                        v.CwLast := r.Final;
                        v.Final  := '0';
                        v.Fsm    := Collect_s;
                        v.Idx    := 0;
                    else
                        v.Idx := r.Idx + 1;
                    end if;
                end if;

            when others =>
                v.Fsm := Collect_s;

        end case;

        -- Entry of a value into the block and update of the code lengths
        if Accept_v then
            v.Buf(r.Idx) := Val_v;
            if Val_v /= 0 then
                v.AllZero := '0';
            end if;

            for k in 0 to KMax_c loop
                v.SumK(k) := satAdd(r.SumK(k), resize(shift_right(Val_v, k), LenW_c + 18)(LenW_c - 1 downto 0));
                if shift_right(Val_v, k) > Sat_c then
                    v.SumK(k) := to_unsigned(Sat_c, LenW_c);
                end if;
            end loop;

            if (r.Idx mod 2) = 1 then
                v.SumSe := satAdd(r.SumSe, secondExt(r.Prev, Val_v) + 1);
            else
                v.Prev := Val_v;
            end if;
            if r.Idx = J_c - 1 then
                v.Fsm := Select_s;
            else
                v.Idx := r.Idx + 1;
                if v.Final = '1' then
                    v.Fsm := Pad_s;
                end if;
            end if;
        end if;

        -- A new block starts with empty statistics
        if (r.Fsm = Select_s and r.AllZero = '1') or r.Fsm = SelectDone_s then
            v.SumK    := (others => (others => '0'));
            v.SumSe   := (others => '0');
            v.AllZero := '1';
        end if;

        r_next <= v;
    end process;

    Cw_Valid  <= r.CwValid;
    Cw_Data   <= r.CwData;
    Cw_Length <= std_logic_vector(r.CwLength);
    Cw_Last   <= r.CwLast;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Fsm      <= Collect_s;
                r.Idx      <= 0;
                r.SumK     <= (others => (others => '0'));
                r.SumSe    <= (others => '0');
                r.AllZero  <= '1';
                r.Final    <= '0';
                r.ZeroRun  <= 0;
                r.BlkInRef <= 0;
                r.FsActive <= '0';
                r.CwValid  <= '0';
            end if;
        end if;
    end process;

end architecture;
