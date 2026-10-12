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
-- One value per clock cycle enters one of three block buffers while the code lengths of all options
-- accumulate. The shortest option of a complete block is selected in a pipelined comparison, and the
-- block is output while the next blocks fill: up to two fundamental sequence
-- codewords, or up to four uncoded values or split bits, form one codeword per clock cycle.
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
    use olo.olo_base_pkg_attribute.all;

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
        RefInterval_g     : positive range 1 to 4096 := 4096;
        RamStyle_g        : string                   := "auto"
    );
    port (
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Entropy coder input sequence
        In_Valid      : in    std_logic;
        In_Ready      : out   std_logic;
        In_Data       : in    std_logic_vector(maximum(DynamicRange_g, 16) - 1 downto 0);
        In_Last       : in    std_logic;
        -- Codewords
        Cw_Valid      : out   std_logic;
        Cw_Ready      : in    std_logic;
        Cw_Data       : out   std_logic_vector(CwWidth_c - 1 downto 0);
        Cw_Length     : out   std_logic_vector(CwLenWidth_c - 1 downto 0);
        Cw_Last       : out   std_logic;
        -- Memory errors (pulses)
        Ecc_Sec       : out   std_logic;
        Ecc_Ded       : out   std_logic;
        -- Error injection into the next write of the codeword buffer: a single or a double bit error
        ErrInj_Buffer : in    std_logic := '0';
        ErrInj_Double : in    std_logic := '0'
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
    -- Values per codeword: uncoded values (4 or 3 of up to 32 bits); fundamental sequence codewords
    constant Lanes_c  : positive := 4;
    constant NcPer_c  : positive := minimum(Lanes_c, (CwWidth_c - 6) / N_c);
    constant Banks_c  : positive := 3;
    -- Candidate options: no compression, second extension, split-sample k = 0 to KMax
    constant NCand_c  : positive := 2 + toInt(KMax_c >= 0) * (KArr_c + 1);
    constant TreeL_c  : natural  := log2ceil(NCand_c);
    constant NPad_c   : positive := 2 ** TreeL_c;
    constant TreeA_c  : natural  := minimum(TreeL_c, 3);
    constant SelW_c   : positive := 16;

    type BufArr_t is array (0 to J_c - 1) of unsigned(N_c - 1 downto 0);
    type BankArr_t is array (0 to Banks_c - 1) of BufArr_t;
    type GamArr_t is array (0 to J_c / 2 - 1) of unsigned(LenW_c - 1 downto 0);
    type GamBank_t is array (0 to Banks_c - 1) of GamArr_t;
    type SumArr_t is array (0 to KArr_c) of unsigned(LenW_c - 1 downto 0);

    type Cand_r is record
        Len : unsigned(SelW_c - 1 downto 0);
        Idx : natural range 0 to NPad_c - 1;
    end record;

    type CandArr_t is array (0 to NPad_c - 1) of Cand_r;

    type Phase_t is (Idle_s, Zero_s, Main_s, Lsb_s);

    type TwoProcess_r is record
        -- Collection of a block into bank CBank, code lengths of the options
        Bank     : BankArr_t;
        Gam      : GamBank_t;
        BankFull : std_logic_vector(0 to Banks_c - 1);
        CBank    : natural range 0 to Banks_c - 1;
        Idx      : natural range 0 to J_c - 1;
        SumK     : SumArr_t;
        SumSe    : unsigned(LenW_c - 1 downto 0);
        AllZero  : std_logic;
        Prev     : unsigned(N_c - 1 downto 0);
        Final    : std_logic;
        -- Selection of the shortest option (three stages)
        S1Valid  : std_logic;
        S1Bank   : natural range 0 to Banks_c - 1;
        S1Zero   : std_logic;
        S1Final  : std_logic;
        S1SumK   : SumArr_t;
        S1SumSe  : unsigned(LenW_c - 1 downto 0);
        S2Valid  : std_logic;
        S2Bank   : natural range 0 to Banks_c - 1;
        S2Zero   : std_logic;
        S2Final  : std_logic;
        S2Cand   : CandArr_t;
        S3Valid  : std_logic;
        S3Bank   : natural range 0 to Banks_c - 1;
        S3Zero   : std_logic;
        S3Final  : std_logic;
        S3Cand   : CandArr_t;
        -- Zero-block runs within a segment (CCSDS 121.0-B-3 3.5), blocks within the reference
        -- sample interval
        ZeroRun  : natural range 0 to 64;
        BlkInRef : natural range 0 to RefInterval_g - 1;
        -- Output of a block: zero-block CDS, then the block CDS
        Phase    : Phase_t;
        EBank    : natural range 0 to Banks_c - 1;
        EFinal   : std_logic;
        EBlock   : std_logic;
        ZeroFs   : natural range 0 to 64;
        Opt      : natural range 0 to NPad_c - 1;
        K        : natural range 0 to KArr_c;
        EIdx     : natural range 0 to J_c;
        IdPend   : std_logic;
        FsRem    : natural range 0 to 2 ** 15 - 1;
        FsActive : std_logic;
        -- Fundamental sequence lengths of the entries EIdx and EIdx + 1
        ZA       : natural range 0 to 2 ** 15 - 1;
        ZB       : natural range 0 to 2 ** 15 - 1;
        -- Codeword
        CwValid  : std_logic;
        CwData   : std_logic_vector(CwWidth_c - 1 downto 0);
        CwLength : unsigned(CwLenWidth_c - 1 downto 0);
        CwLast   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- The block buffers are registers: synthesis shall not infer memories without ECC from them
    attribute ram_style of r    : signal is "registers";
    attribute ramstyle of r     : signal is "logic";
    attribute syn_ramstyle of r : signal is "registers";

    -- Codeword register into the codeword buffer
    signal BufReady : std_logic;

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

    -- Levels of the comparison tree: of two candidates the right one only if strictly shorter, which
    -- keeps the order of the ties of 3.7.4 (no compression, second extension, smallest k)
    function reduceTree (c : CandArr_t; levels : natural) return CandArr_t is
        variable R_v : CandArr_t := c;
        variable N_v : natural   := NPad_c;
    begin

        for l in 1 to levels loop
            N_v := N_v / 2;

            for i in 0 to NPad_c / 2 - 1 loop
                if i < N_v then
                    if R_v(2 * i + 1).Len < R_v(2 * i).Len then
                        R_v(i) := R_v(2 * i + 1);
                    else
                        R_v(i) := R_v(2 * i);
                    end if;
                end if;
            end loop;

        end loop;

        return R_v;
    end function;

    -- Fundamental sequence codeword lengths (zeros) of a block entry
    function fsZeros (b : BufArr_t; g : GamArr_t; opt : natural; k : natural; i : natural) return natural is
    begin
        if opt = 1 then
            return to_integer(g(i mod (J_c / 2)));
        end if;
        return to_integer(shift_right(b(i mod J_c), k)(minimum(N_c, 15) - 1 downto 0));
    end function;

begin

    p_comb : process (all) is
        variable v        : TwoProcess_r;
        variable Val_v    : unsigned(N_c - 1 downto 0);
        variable Accept_v : boolean;
        variable Cand_v   : CandArr_t;
        variable SegEnd_v : boolean;
        variable Run_v    : natural range 0 to 64;
        variable Count_v  : natural range 0 to J_c;
        variable Z0_v     : natural range 0 to 2 ** 15 - 1;
        variable Z1_v     : natural range 0 to 2 ** 15 - 1;
        variable Data_v   : unsigned(CwWidth_c - 1 downto 0);
        variable Len_v    : natural range 0 to CwWidth_c;
        variable Id_v     : unsigned(5 downto 0);
        variable IdLen_v  : natural range 0 to 6;
        variable Done_v   : boolean;
        variable Per_v    : natural range 1 to Lanes_c;
        variable ZC_v     : natural range 0 to 2 ** 15 - 1;
        variable ZD_v     : natural range 0 to 2 ** 15 - 1;
    begin
        v := r;

        if BufReady = '1' then
            v.CwValid := '0';
        end if;

        -------------------------------------------------------------------------------------------
        -- Collection: one value per cycle, zeros after the last value up to the end of the block
        -- (CCSDS 123.0-B-2 5.4.3.4.2.7)
        -------------------------------------------------------------------------------------------
        In_Ready <= '0';
        Accept_v := false;
        Val_v    := (others => '0');
        if r.BankFull(r.CBank) = '0' and (r.Idx /= J_c - 1 or r.S1Valid = '0') then
            if r.Final = '1' then
                Accept_v := true;
            else
                In_Ready <= '1';
                if In_Valid = '1' then
                    Val_v    := resize(unsigned(In_Data), N_c);
                    Accept_v := true;
                    v.Final  := In_Last;
                end if;
            end if;
        end if;

        if Accept_v then
            v.Bank(r.CBank)(r.Idx) := Val_v;
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
                v.Gam(r.CBank)(r.Idx / 2) := secondExt(r.Prev, Val_v);
                v.SumSe                   := satAdd(r.SumSe, secondExt(r.Prev, Val_v) + 1);
            else
                v.Prev := Val_v;
            end if;

            if r.Idx = J_c - 1 then
                -- Block complete: to the selection, the next block into the other bank
                v.S1Valid           := '1';
                v.S1Bank            := r.CBank;
                v.S1Zero            := v.AllZero;
                v.S1Final           := v.Final;
                v.S1SumK            := v.SumK;
                v.S1SumSe           := v.SumSe;
                v.BankFull(r.CBank) := '1';
                v.CBank             := (r.CBank + 1) mod Banks_c;
                v.Idx               := 0;
                v.SumK              := (others => (others => '0'));
                v.SumSe             := (others => '0');
                v.AllZero           := '1';
                v.Final             := '0';
            else
                v.Idx := r.Idx + 1;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Selection: lengths of the options, comparison tree in two stages
        -------------------------------------------------------------------------------------------
        if r.S1Valid = '1' and r.S2Valid = '0' then
            Cand_v := (others => (Len => (others => '1'), Idx => 0));

            for i in 0 to NPad_c - 1 loop
                Cand_v(i).Idx := i;
            end loop;

            Cand_v(0).Len := to_unsigned(N_c * J_c + IdBits_c, SelW_c);
            Cand_v(1).Len := resize(r.S1SumSe, SelW_c) + IdBits_c + 1;

            for k in 0 to KMax_c loop
                Cand_v(2 + k).Len := resize(r.S1SumK(k), SelW_c) + J_c * (k + 1) + IdBits_c;
            end loop;

            v.S2Valid := '1';
            v.S2Bank  := r.S1Bank;
            v.S2Zero  := r.S1Zero;
            v.S2Final := r.S1Final;
            v.S2Cand  := reduceTree(Cand_v, TreeA_c);
            v.S1Valid := '0';
        end if;

        if r.S2Valid = '1' and r.S3Valid = '0' then
            v.S3Valid := '1';
            v.S3Bank  := r.S2Bank;
            v.S3Zero  := r.S2Zero;
            v.S3Final := r.S2Final;
            v.S3Cand  := reduceTree(r.S2Cand, TreeL_c - TreeA_c);
            v.S2Valid := '0';
        end if;

        -------------------------------------------------------------------------------------------
        -- Fundamental sequence lengths read ahead: of the entries 0 and 1 of the next block at its
        -- start, else of the entries EIdx + 2 and EIdx + 3 of the block in output
        -------------------------------------------------------------------------------------------
        if r.Phase = Idle_s then
            ZC_v := fsZeros(r.Bank(r.S3Bank), r.Gam(r.S3Bank), r.S3Cand(0).Idx, maximum(r.S3Cand(0).Idx - 2, 0), 0);
            ZD_v := fsZeros(r.Bank(r.S3Bank), r.Gam(r.S3Bank), r.S3Cand(0).Idx, maximum(r.S3Cand(0).Idx - 2, 0), 1);
        else
            ZC_v := fsZeros(r.Bank(r.EBank), r.Gam(r.EBank), r.Opt, r.K, r.EIdx + 2);
            ZD_v := fsZeros(r.Bank(r.EBank), r.Gam(r.EBank), r.Opt, r.K, r.EIdx + 3);
        end if;

        -------------------------------------------------------------------------------------------
        -- Start of the output of a block (zero-block runs: 3.5)
        -------------------------------------------------------------------------------------------
        if r.Phase = Idle_s and r.S3Valid = '1' then
            v.ZA      := ZC_v;
            v.ZB      := ZD_v;
            v.S3Valid := '0';
            SegEnd_v  := (r.BlkInRef mod 64) = 63 or r.BlkInRef = RefInterval_g - 1 or r.S3Final = '1';
            if r.BlkInRef = RefInterval_g - 1 or r.S3Final = '1' then
                v.BlkInRef := 0;
            else
                v.BlkInRef := r.BlkInRef + 1;
            end if;
            v.EBank    := r.S3Bank;
            v.EFinal   := r.S3Final;
            v.Opt      := r.S3Cand(0).Idx;
            v.K        := maximum(r.S3Cand(0).Idx - 2, 0);
            v.EIdx     := 0;
            v.IdPend   := '1';
            v.FsActive := '0';
            if r.S3Zero = '1' then
                Run_v    := r.ZeroRun + 1;
                v.EBlock := '0';
                if SegEnd_v then
                    -- Remainder of segment for runs of five or more blocks
                    if Run_v >= 5 then
                        v.ZeroFs := 4;
                    else
                        v.ZeroFs := Run_v - 1;
                    end if;
                    v.ZeroRun := 0;
                    v.Phase   := Zero_s;
                else
                    v.ZeroRun            := Run_v;
                    v.BankFull(r.S3Bank) := '0';
                end if;
            else
                v.EBlock := '1';
                if r.ZeroRun > 0 then
                    -- The run of all-zeros blocks before this block
                    if r.ZeroRun <= 4 then
                        v.ZeroFs := r.ZeroRun - 1;
                    else
                        v.ZeroFs := r.ZeroRun;
                    end if;
                    v.ZeroRun := 0;
                    v.Phase   := Zero_s;
                else
                    v.Phase := Main_s;
                end if;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Output: one codeword per cycle
        -------------------------------------------------------------------------------------------
        Data_v := (others => '0');
        Len_v  := 0;
        Done_v := false;
        -- Option identifier of the block CDS (CCSDS 121.0-B-3 5.2), in front of the first part
        if r.Opt = 0 then
            Id_v    := to_unsigned(2 ** IdBits_c - 1, 6);
            IdLen_v := IdBits_c;
        elsif r.Opt = 1 then
            Id_v    := to_unsigned(1, 6);
            IdLen_v := IdBits_c + 1;
        else
            Id_v    := to_unsigned(r.K + 1, 6);
            IdLen_v := IdBits_c;
        end if;

        if r.CwValid = '0' or BufReady = '1' then

            case r.Phase is

                -- Zero-block CDS: option identifier and the fundamental sequence codeword of the run
                when Zero_s =>
                    v.CwValid  := '1';
                    v.CwData   := std_logic_vector(to_unsigned(1, CwWidth_c));
                    v.CwLength := to_unsigned(IdBits_c + 1 + r.ZeroFs + 1, CwLenWidth_c);
                    v.CwLast   := r.EFinal and not r.EBlock;
                    if r.EBlock = '1' then
                        v.Phase := Main_s;
                    else
                        v.Phase             := Idle_s;
                        v.BankFull(r.EBank) := '0';
                    end if;

                -- Uncoded values, second extension or fundamental sequence codewords of the block
                when Main_s =>
                    if r.Opt = 0 then
                        -- No compression: up to NcPer_c values
                        Per_v := minimum(NcPer_c, J_c - r.EIdx);

                        for l in 0 to Lanes_c - 1 loop
                            if l < Per_v then
                                Data_v := shift_left(Data_v, N_c) or resize(r.Bank(r.EBank)((r.EIdx + l) mod J_c), CwWidth_c);
                                Len_v  := Len_v + N_c;
                            end if;
                        end loop;

                        v.EIdx := r.EIdx + Per_v;
                        Done_v := r.EIdx + Per_v = J_c;
                    else
                        -- Fundamental sequence codewords (zeros and a '1'): two per codeword when they fit;
                        -- longer ones in parts of CwWidth_c - 8 zeros
                        Count_v := J_c;
                        if r.Opt = 1 then
                            Count_v := J_c / 2;
                        end if;
                        Z0_v := r.ZA;
                        Z1_v := r.ZB;
                        if r.FsActive = '1' then
                            Z0_v := r.FsRem;
                        end if;
                        if Z0_v >= CwWidth_c - 8 then
                            Len_v      := CwWidth_c - 8;
                            v.FsRem    := Z0_v - (CwWidth_c - 8);
                            v.FsActive := '1';
                        elsif r.EIdx + 1 < Count_v and r.FsActive = '0' and Z0_v + Z1_v + 2 <= CwWidth_c - 8 then
                            Data_v     := shift_left(to_unsigned(1, CwWidth_c), Z1_v + 1) or to_unsigned(1, CwWidth_c);
                            Len_v      := Z0_v + Z1_v + 2;
                            v.EIdx     := r.EIdx + 2;
                            v.ZA       := ZC_v;
                            v.ZB       := ZD_v;
                            v.FsActive := '0';
                            Done_v     := r.EIdx + 2 = Count_v;
                        else
                            Data_v     := to_unsigned(1, CwWidth_c);
                            Len_v      := Z0_v + 1;
                            v.EIdx     := r.EIdx + 1;
                            v.ZA       := r.ZB;
                            v.ZB       := ZC_v;
                            v.FsActive := '0';
                            Done_v     := r.EIdx + 1 = Count_v;
                        end if;
                    end if;
                    if r.IdPend = '1' then
                        Data_v   := Data_v or shift_left(resize(Id_v, CwWidth_c), Len_v);
                        Len_v    := Len_v + IdLen_v;
                        v.IdPend := '0';
                    end if;
                    v.CwValid  := '1';
                    v.CwData   := std_logic_vector(Data_v);
                    v.CwLength := to_unsigned(Len_v, CwLenWidth_c);
                    v.CwLast   := '0';
                    if Done_v then
                        v.EIdx := 0;
                        if r.Opt >= 2 and r.K > 0 then
                            v.Phase := Lsb_s;
                        else
                            v.CwLast            := r.EFinal;
                            v.Phase             := Idle_s;
                            v.BankFull(r.EBank) := '0';
                        end if;
                    end if;

                -- Split bits of the split-sample options: up to Lanes_c fields of k bits
                when Lsb_s =>
                    Per_v := minimum(minimum(Lanes_c, CwWidth_c / maximum(r.K, 1)), J_c - r.EIdx);

                    for l in 0 to Lanes_c - 1 loop
                        if l < Per_v then
                            Data_v := shift_left(Data_v, r.K) or
                                      resize(r.Bank(r.EBank)((r.EIdx + l) mod J_c) and
                                               (shift_left(to_unsigned(1, N_c), r.K) - 1), CwWidth_c);
                            Len_v  := Len_v + r.K;
                        end if;
                    end loop;

                    v.CwValid  := '1';
                    v.CwData   := std_logic_vector(Data_v);
                    v.CwLength := to_unsigned(Len_v, CwLenWidth_c);
                    v.CwLast   := '0';
                    v.EIdx     := r.EIdx + Per_v;
                    if r.EIdx + Per_v = J_c then
                        v.CwLast            := r.EFinal;
                        v.EIdx              := 0;
                        v.Phase             := Idle_s;
                        v.BankFull(r.EBank) := '0';
                    end if;

                when others =>
                    null;

            end case;

        end if;

        r_next <= v;
    end process;

    i_cw_buffer : entity work.ocp_cw_buffer
        generic map (
            Depth_g    => 16,
            RamStyle_g => RamStyle_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            In_Valid      => r.CwValid,
            In_Ready      => BufReady,
            In_Data       => r.CwData,
            In_Length     => std_logic_vector(r.CwLength),
            In_Last       => r.CwLast,
            In_Level      => open,
            Cw_Valid      => Cw_Valid,
            Cw_Ready      => Cw_Ready,
            Cw_Data       => Cw_Data,
            Cw_Length     => Cw_Length,
            Cw_Last       => Cw_Last,
            Ecc_Sec       => Ecc_Sec,
            Ecc_Ded       => Ecc_Ded,
            ErrInj_Double => ErrInj_Double,
            ErrInj_Valid  => ErrInj_Buffer
        );

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.BankFull <= (others => '0');
                r.CBank    <= 0;
                r.Idx      <= 0;
                r.SumK     <= (others => (others => '0'));
                r.SumSe    <= (others => '0');
                r.AllZero  <= '1';
                r.Final    <= '0';
                r.S1Valid  <= '0';
                r.S2Valid  <= '0';
                r.S3Valid  <= '0';
                r.ZeroRun  <= 0;
                r.BlkInRef <= 0;
                r.Phase    <= Idle_s;
                r.FsActive <= '0';
                r.CwValid  <= '0';
            end if;
        end if;
    end process;

end architecture;
