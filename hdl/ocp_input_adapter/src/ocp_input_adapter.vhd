---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Input adapter: takes service data units (SDUs) of big-endian sample containers of ceil(D/8) bytes
-- from a byte stream and outputs one sample per beat to ocp_core. The user signal of an SDU marks
-- the last SDU of an image and flags faulty SDUs; a faulty SDU, or one that does not hold a whole
-- number of samples, ends its image with an error, and the rest of that image is discarded.
--
-- Documentation: hdl/ocp_input_adapter/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;

library work;
    use work.ocp_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocp_input_adapter is
    generic (
        -- Width of the SDU stream in bits (8, 16, 32, 64 or 128)
        InWidth_g       : positive                                   := 128;
        -- Bits per sample (D); a sample container has ceil(D/8) bytes
        DynamicRange_g  : positive range 2 to 32                     := 16;
        -- User signal: end mark (In_User and UserLastMask_g) = UserLastValue_g, faulty SDU
        -- (In_User and UserErrorMask_g) /= 0, both evaluated with the last beat of an SDU
        UserWidth_g     : positive range 1 to 64                     := 1;
        UserLastMask_g  : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0');
        UserLastValue_g : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0');
        UserErrorMask_g : std_logic_vector(UserWidth_g - 1 downto 0) := (others => '0')
    );
    port (
        Clk             : in    std_logic;
        Rst             : in    std_logic;
        -- SDU stream: byte n of a beat in In_Data(8n + 7 downto 8n), the first byte of an SDU in byte 0
        -- of its first beat; all bytes valid except in the last beat, contiguous from byte 0
        In_Valid        : in    std_logic;
        In_Ready        : out   std_logic;
        In_Data         : in    std_logic_vector(InWidth_g - 1 downto 0);
        In_Keep         : in    std_logic_vector(InWidth_g / 8 - 1 downto 0);
        In_Last         : in    std_logic;
        In_User         : in    std_logic_vector(UserWidth_g - 1 downto 0);
        -- Samples to ocp_core (UseInLast_g): Out_Last on the last sample of an image, Out_Error with it
        -- when the image ends with an error
        Out_Valid       : out   std_logic;
        Out_Ready       : in    std_logic;
        Out_Data        : out   std_logic_vector(DynamicRange_g - 1 downto 0);
        Out_Last        : out   std_logic;
        Out_Error       : out   std_logic;
        -- Events (pulses): faulty SDU forwarded, SDU discarded
        Ev_SduError     : out   std_logic;
        Ev_SduDiscarded : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocp_input_adapter is

    -- Container of a sample: bytes and bits
    constant Bytes_c  : positive := (DynamicRange_g + 7) / 8;
    constant CntW_c   : positive := 8 * Bytes_c;
    -- One container per beat: no width converter
    constant Bypass_c : boolean := InWidth_g = CntW_c;

    -- Run: SDUs go through the width converter; Discard: SDUs are taken and dropped up to and
    -- including the next SDU with the end mark
    type State_t is (Run_s, Discard_s);

    type TwoProcess_r is record
        State     : State_t;
        Pending   : std_logic;
        User      : std_logic_vector(UserWidth_g - 1 downto 0);
        EvError   : std_logic;
        EvDiscard : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Width converter; its inputs come from one process, so that they change in the same delta cycle (the
    -- converter checks the byte enables of every valid beat in simulation)
    signal ConvInValid  : std_logic;
    signal ConvInReady  : std_logic;
    signal ConvInData   : std_logic_vector(InWidth_g - 1 downto 0);
    signal ConvInBe     : std_logic_vector(InWidth_g / 8 - 1 downto 0);
    signal ConvInLast   : std_logic;
    signal ConvOutValid : std_logic;
    signal ConvOutReady : std_logic;
    signal ConvData     : std_logic_vector(CntW_c - 1 downto 0);
    signal ConvBe       : std_logic_vector(Bytes_c - 1 downto 0);
    signal ConvLast     : std_logic;

    function isMark (user : std_logic_vector) return boolean is
    begin
        return (user and UserLastMask_g) = UserLastValue_g;
    end function;

    function isFault (user : std_logic_vector) return boolean is
    begin
        return (user and UserErrorMask_g) /= (user'range => '0');
    end function;

begin

    assert InWidth_g = 8 or InWidth_g = 16 or InWidth_g = 32 or InWidth_g = 64 or InWidth_g = 128
        report "ocp_input_adapter: InWidth_g must be 8, 16, 32, 64 or 128"
        severity failure;
    assert (UserLastValue_g and not UserLastMask_g) = (UserLastValue_g'range => '0')
        report "ocp_input_adapter: UserLastValue_g must lie within UserLastMask_g"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- SDU control and sample extraction
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable User_v  : std_logic_vector(UserWidth_g - 1 downto 0);
        variable Mark_v  : boolean;
        variable Fault_v : boolean;
        variable Smp_v   : std_logic_vector(CntW_c - 1 downto 0);
    begin
        v           := r;
        v.EvError   := '0';
        v.EvDiscard := '0';

        In_Ready    <= '0';
        ConvInValid <= '0';
        ConvInData  <= In_Data;
        ConvInBe    <= In_Keep;
        ConvInLast  <= In_Last;

        case r.State is

            when Run_s =>
                -- The next SDU waits until the last sample of the current one has been taken: the
                -- discard decision depends on its length check at the converter output
                ConvInValid <= In_Valid and not r.Pending;
                In_Ready    <= ConvInReady and not r.Pending;
                if In_Valid = '1' and ConvInReady = '1' and r.Pending = '0' and In_Last = '1' then
                    v.User    := In_User;
                    v.Pending := '1';
                end if;

            when Discard_s =>
                In_Ready <= '1';
                if In_Valid = '1' and In_Last = '1' then
                    v.EvDiscard := '1';
                    if isMark(In_User) then
                        v.State := Run_s;
                    end if;
                end if;

            when others =>
                v.State := Run_s;

        end case;

        -- End mark and fault of the SDU of the last container (without converter the last beat is the
        -- last container, its user signal is the current one)
        if Bypass_c then
            User_v := In_User;
        else
            User_v := r.User;
        end if;
        Mark_v  := isMark(User_v);
        Fault_v := isFault(User_v) or ConvBe /= (ConvBe'range => '1');

        Out_Valid    <= ConvOutValid;
        ConvOutReady <= Out_Ready;
        Out_Last     <= ConvLast and toSl(Mark_v or Fault_v);
        Out_Error    <= ConvLast and toSl(Fault_v);

        if ConvOutValid = '1' and Out_Ready = '1' and ConvLast = '1' then
            v.Pending := '0';
            v.EvError := toSl(Fault_v);
            if Fault_v and not Mark_v then
                v.State := Discard_s;
            end if;
        end if;

        -- Big-endian container: the first byte is the most significant one; missing bytes of an
        -- incomplete last container are zero
        for i in 0 to Bytes_c - 1 loop
            if ConvBe(i) = '1' then
                Smp_v(8 * (Bytes_c - 1 - i) + 7 downto 8 * (Bytes_c - 1 - i)) := ConvData(8 * i + 7 downto 8 * i);
            else
                Smp_v(8 * (Bytes_c - 1 - i) + 7 downto 8 * (Bytes_c - 1 - i)) := (others => '0');
            end if;
        end loop;

        Out_Data <= Smp_v(DynamicRange_g - 1 downto 0);

        r_next <= v;
    end process;

    Ev_SduError     <= r.EvError;
    Ev_SduDiscarded <= r.EvDiscard;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.State     <= Run_s;
                r.Pending   <= '0';
                r.EvError   <= '0';
                r.EvDiscard <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Width converter: SDU beats to sample containers
    -----------------------------------------------------------------------------------------------
    g_convert : if not Bypass_c generate

        i_conv : entity olo.olo_base_wconv_n2m
            generic map (
                InWidth_g  => InWidth_g,
                OutWidth_g => CntW_c,
                UseBe_g    => true
            )
            port map (
                Clk       => Clk,
                Rst       => Rst,
                In_Valid  => ConvInValid,
                In_Ready  => ConvInReady,
                In_Data   => ConvInData,
                In_Be     => ConvInBe,
                In_Last   => ConvInLast,
                Out_Valid => ConvOutValid,
                Out_Ready => ConvOutReady,
                Out_Data  => ConvData,
                Out_Be    => ConvBe,
                Out_Last  => ConvLast
            );

    end generate;

    -- One container per beat
    g_bypass : if Bypass_c generate
        ConvOutValid <= ConvInValid;
        ConvInReady  <= ConvOutReady;
        ConvData     <= ConvInData;
        ConvBe       <= ConvInBe;
        ConvLast     <= ConvInLast;
    end generate;

end architecture;
