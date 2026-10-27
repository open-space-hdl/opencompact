# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Bit-exact reference model of a CCSDS 123.0-B-2 compressor.

The model implements the compressor of CCSDS 123.0-B-2 (Issue 2, Technical Corrigendum 3) from the clause text:
header (5.3), predictor and quantizer (4), the three entropy coders (5.4.3) and the input orders (5.4.2). It is
the source of the intermediate reference data of the OpenCompact unit testbenches (mapped quantizer indices,
codewords). The compressed images of the testbenches come from the CNES reference software (tools/golden.py).
decompress() is the decoder: it reconstructs the clipped quantizer bin centers of a compressed image of any
configuration, as the CNES reference decoder does (tools/tests).

A configuration is a dict with the parameter names of the CNES header tool (large_n_x, large_d, ...); see
`default_config()`. Vector parameters (a_vector, phi_vector, ...) repeat their last element as needed.
"""

import math
import sys

from ocp_low_entropy_codes import CODES, FLUSH, LIMITS, THRESHOLDS


# ------------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------------
def default_config():
    """Lossless, full prediction, BIP, sample-adaptive coder (the defaults of the testbench configurations)."""
    return {
        "user_defined_data": 0,
        "large_n_x": 8, "large_n_y": 8, "large_n_z": 4,
        "sample_type": 0, "large_d": 16,
        "sample_encoding_order": 0, "large_m": 4,
        "large_b": 1,
        "entropy_coder_type": 0,
        "quantizer_fidelity_control_method": 0,
        "supplementary_information_tables": [],
        # predictor
        "large_p": 3, "prediction_mode": 0, "local_sum_type": 0,
        "large_r": 64, "large_omega": 19, "log_two_t_inc": 6, "v_min": -1, "v_max": 3,
        "weight_exponent_offset_flag": 0, "weight_exponent_offset_table_flag": 0, "zeta_vector": [0],
        "weight_initialization_method": 0, "weight_initialization_table_flag": 0, "large_q": 0,
        "large_lambda_vector": [0],
        # quantizer
        "periodic_updating_flag": 0, "u": 0,
        "absolute_error_limit_assignment_method": 0, "large_d_large_a": 1, "a_vector": [0],
        "relative_error_limit_assignment_method": 0, "large_d_large_r": 1, "r_vector": [0],
        # sample representatives
        "sample_representative_flag": 0, "large_theta": 0,
        "band_varying_damping_flag": 0, "damping_table_flag": 0, "phi_vector": [0],
        "band_varying_offset_flag": 0, "offset_table_flag": 0, "psi_vector": [0],
        # sample-adaptive and hybrid coder
        "large_u_max": 16, "gamma_star": 6, "gamma_0": 1,
        "band_varying_k_flag": 0, "accumulator_initialization_table_flag": 0, "k_prime_prime_vector": [3],
        "hybrid_initial_accumulator": [0],
        # block-adaptive coder
        "large_j": 16, "restricted_code_options_flag": 0, "r": 4096,
    }


def vec(cfg, name, n):
    """Vector parameter extended to n elements by repeating the last element."""
    v = list(cfg[name])
    if not v:
        v = [0]
    return (v + [v[-1]] * n)[:n]


class Params:
    """Derived quantities of a configuration."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.nx = cfg["large_n_x"]
        self.ny = cfg["large_n_y"]
        self.nz = cfg["large_n_z"]
        self.d = cfg["large_d"]
        self.signed = cfg["sample_type"] == 1
        if self.signed:
            self.smin, self.smax, self.smid = -(1 << (self.d - 1)), (1 << (self.d - 1)) - 1, 0
        else:
            self.smin, self.smax, self.smid = 0, (1 << self.d) - 1, 1 << (self.d - 1)
        self.bsq = cfg["sample_encoding_order"] == 1
        self.m = cfg["large_m"]
        self.p = cfg["large_p"]
        self.full = cfg["prediction_mode"] == 0
        self.ls = cfg["local_sum_type"]
        self.reg = cfg["large_r"]
        self.om = cfg["large_omega"]
        self.tinc_log = cfg["log_two_t_inc"]
        self.vmin = cfg["v_min"]
        self.vmax = cfg["v_max"]
        self.wmin = -(1 << (self.om + 2))
        self.wmax = (1 << (self.om + 2)) - 1
        self.fid = cfg["quantizer_fidelity_control_method"]
        self.use_abs = self.fid in (1, 3)
        self.use_rel = self.fid in (2, 3)
        self.periodic = self.fid != 0 and cfg["periodic_updating_flag"] == 1
        self.u = cfg["u"]
        self.theta = cfg["large_theta"] if cfg["sample_representative_flag"] else 0
        nz = self.nz
        self.a = vec(cfg, "a_vector", nz)
        self.rr = vec(cfg, "r_vector", nz)
        self.phi = vec(cfg, "phi_vector", nz) if self.theta else [0] * nz
        self.psi = vec(cfg, "psi_vector", nz) if self.theta else [0] * nz
        # weight exponent offsets: per band [zeta_star (full mode only), zeta(1) .. zeta(Pz*)]
        self.zeta_star = [0] * nz
        self.zeta = [[0] * (self.p + 1) for _ in range(nz)]
        if cfg["weight_exponent_offset_flag"]:
            flat = self.band_table(cfg["zeta_vector"], 1)
            for z in range(nz):
                row = flat[z]
                if self.full:
                    self.zeta_star[z] = row[0]
                    row = row[1:]
                for i in range(1, self.pz(z) + 1):
                    self.zeta[z][i] = row[i - 1]
        self.custom_weights = cfg["weight_initialization_method"] == 1
        if self.custom_weights:
            self.lam = self.band_table(cfg["large_lambda_vector"], 3)

    def pz(self, z):
        return min(z, self.p)

    def cz(self, z):
        return self.pz(z) + (3 if self.full else 0)

    def band_table(self, values, full_extra):
        """Splits a flat per-band table (as in the header: per band Pz* (+ full_extra in full mode) entries)."""
        v = list(values) if values else [0]
        out = []
        pos = 0
        for z in range(self.nz):
            n = self.pz(z) + (full_extra if self.full else 0)
            row = []
            for _ in range(n):
                row.append(v[pos] if pos < len(v) else v[-1])
                pos += 1
            out.append(row)
        return out


# ------------------------------------------------------------------------------------------------
# Bit writer
# ------------------------------------------------------------------------------------------------
class BitWriter:
    """Bit stream, most significant bit first. The pending bits collect in an integer of at most FLUSH_BITS bits plus
    one codeword; full bytes then move to a bytearray, so the cost is linear in the length of the stream."""

    FLUSH_BITS = 4096

    def __init__(self):
        self.buf = bytearray()
        self.acc = 0        # pending bits, the last one in bit 0
        self.pending = 0    # number of pending bits
        self.n = 0          # number of bits written

    def put(self, value, width):
        if width == 0:
            return
        assert 0 <= value < (1 << width), (value, width)
        self.acc = (self.acc << width) | value
        self.pending += width
        self.n += width
        if self.pending >= self.FLUSH_BITS:
            self.flush()

    def flush(self):
        """Moves the full bytes of the pending bits to the buffer."""
        nbytes, rem = divmod(self.pending, 8)
        if nbytes:
            self.buf += (self.acc >> rem).to_bytes(nbytes, "big")
            self.acc &= (1 << rem) - 1
            self.pending = rem

    def put_signed(self, value, width):
        self.put(value & ((1 << width) - 1), width)

    def put_bits(self, bits):
        for b in bits:
            self.put(1 if b == "1" else 0, 1)

    def align(self, unit_bits=8):
        rem = self.n % unit_bits
        if rem:
            self.put(0, unit_bits - rem)

    def to_bytes(self):
        assert self.n % 8 == 0
        self.flush()
        return bytes(self.buf)


# ------------------------------------------------------------------------------------------------
# Header (5.3)
# ------------------------------------------------------------------------------------------------
def header(cfg):
    """Returns the header bytes."""
    pr = Params(cfg)
    w = BitWriter()
    d = pr.d
    # Image metadata, essential subpart (table 5-3)
    w.put(cfg["user_defined_data"], 8)
    w.put(pr.nx % 65536, 16)
    w.put(pr.ny % 65536, 16)
    w.put(pr.nz % 65536, 16)
    w.put(cfg["sample_type"], 1)
    w.put(0, 1)
    w.put(1 if d > 16 else 0, 1)
    w.put(d % 16, 4)
    w.put(cfg["sample_encoding_order"], 1)
    w.put(0 if pr.bsq else pr.m % 65536, 16)
    w.put(0, 2)
    w.put(cfg["large_b"] % 8, 3)
    w.put(cfg["entropy_coder_type"], 2)
    w.put(0, 1)
    w.put(pr.fid, 2)
    w.put(0, 2)
    sits = cfg["supplementary_information_tables"]
    w.put(len(sits), 4)
    # Supplementary information tables (5.3.2.3)
    for t in sits:
        w.put(t["type"], 2)
        w.put(0, 2)
        w.put(t["purpose"], 4)
        w.put(0, 1)
        w.put(t["structure"], 2)
        w.put(0, 1)
        w.put(t["user_data"], 4)
        n = {0: 1, 1: pr.nz, 2: pr.nz * pr.nx, 3: pr.ny * pr.nx}[t["structure"]]
        if t["type"] in (0, 1):
            di = t["di"]
            w.put(di % 32, 5)
            for e in t["data"][:n]:
                w.put_signed(e, di) if t["type"] == 1 else w.put(e, di)
        else:
            df, de, beta = t["df"], t["de"], t["beta"]
            w.put(df, 5)
            w.put(de % 8, 3)
            w.put(beta, de)
            for (b, ex, j) in t["data"][:n]:
                w.put(b, 1)
                w.put(ex, de)
                w.put(j, df)
        w.align()
    # Predictor metadata, primary subpart (table 5-6)
    w.put(0, 1)
    w.put(cfg["sample_representative_flag"], 1)
    w.put(pr.p, 4)
    w.put(cfg["prediction_mode"], 1)
    w.put(cfg["weight_exponent_offset_flag"], 1)
    w.put(pr.ls, 2)
    w.put(pr.reg % 64, 6)
    w.put(pr.om - 4, 4)
    w.put(pr.tinc_log - 4, 4)
    w.put(pr.vmin + 6, 4)
    w.put(pr.vmax + 6, 4)
    w.put(cfg["weight_exponent_offset_table_flag"], 1)
    w.put(cfg["weight_initialization_method"], 1)
    w.put(cfg["weight_initialization_table_flag"], 1)
    w.put(cfg["large_q"] if pr.custom_weights else 0, 5)
    # Weight tables subpart (5.3.3.3)
    if cfg["weight_initialization_table_flag"]:
        q = cfg["large_q"]
        for z in range(pr.nz):
            for j in range(pr.cz(z)):
                w.put_signed(pr.lam[z][j], q)
        w.align()
    if cfg["weight_exponent_offset_table_flag"]:
        for z in range(pr.nz):
            if pr.full:
                w.put_signed(pr.zeta_star[z], 4)
            for i in range(1, pr.pz(z) + 1):
                w.put_signed(pr.zeta[z][i], 4)
        w.align()
    # Quantization subpart (5.3.3.4)
    if pr.fid != 0:
        if not pr.bsq:
            w.put(0, 1)
            w.put(1 if pr.periodic else 0, 1)
            w.put(0, 2)
            w.put(pr.u if pr.periodic else 0, 4)
        if pr.use_abs:
            dep = cfg["absolute_error_limit_assignment_method"]
            da = cfg["large_d_large_a"]
            w.put(0, 1)
            w.put(dep, 1)
            w.put(0, 2)
            w.put(da % 16, 4)
            if not pr.periodic:
                for v in (pr.a if dep else pr.a[:1]):
                    w.put(v, da)
                w.align()
        if pr.use_rel:
            dep = cfg["relative_error_limit_assignment_method"]
            dr = cfg["large_d_large_r"]
            w.put(0, 1)
            w.put(dep, 1)
            w.put(0, 2)
            w.put(dr % 16, 4)
            if not pr.periodic:
                for v in (pr.rr if dep else pr.rr[:1]):
                    w.put(v, dr)
                w.align()
    # Sample representative subpart (5.3.3.5)
    if cfg["sample_representative_flag"]:
        th = cfg["large_theta"]
        bvd = cfg["band_varying_damping_flag"]
        bvo = cfg["band_varying_offset_flag"]
        w.put(0, 5)
        w.put(th, 3)
        w.put(0, 1)
        w.put(bvd, 1)
        w.put(cfg["damping_table_flag"], 1)
        w.put(0, 1)
        w.put(0 if bvd else pr.phi[0], 4)
        w.put(0, 1)
        w.put(bvo, 1)
        w.put(cfg["offset_table_flag"], 1)
        w.put(0, 1)
        w.put(0 if bvo else pr.psi[0], 4)
        if cfg["damping_table_flag"]:
            for v in pr.phi:
                w.put(v, th)
            w.align()
        if cfg["offset_table_flag"]:
            for v in pr.psi:
                w.put(v, th)
            w.align()
    # Entropy coder metadata (5.3.4)
    ec = cfg["entropy_coder_type"]
    if ec == 0:
        w.put(cfg["large_u_max"] % 32, 5)
        w.put(cfg["gamma_star"] - 4, 3)
        w.put(cfg["gamma_0"] % 8, 3)
        if cfg["band_varying_k_flag"]:
            w.put(15, 4)
        else:
            w.put(cfg["k_prime_prime_vector"][0], 4)
        w.put(cfg["accumulator_initialization_table_flag"], 1)
        if cfg["accumulator_initialization_table_flag"]:
            for v in vec(cfg, "k_prime_prime_vector", pr.nz):
                w.put(v, 4)
            w.align()
    elif ec == 1:
        w.put(cfg["large_u_max"] % 32, 5)
        w.put(cfg["gamma_star"] - 4, 3)
        w.put(cfg["gamma_0"] % 8, 3)
        w.put(0, 5)
    else:
        w.put(0, 1)
        w.put({8: 0, 16: 1, 32: 2, 64: 3}[cfg["large_j"]], 2)
        w.put(cfg["restricted_code_options_flag"], 1)
        w.put(cfg["r"] % 4096, 12)
    return w.to_bytes()


# ------------------------------------------------------------------------------------------------
# Predictor and quantizer (4)
# ------------------------------------------------------------------------------------------------
def sgn(v):
    return (v > 0) - (v < 0)


def clip(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def mod_r(v, reg):
    """mod*_R: R-bit two's complement wrap (1.6.1)."""
    half = 1 << (reg - 1)
    return ((v + half) % (1 << reg)) - half


class ErrorLimits:
    """Current absolute and relative error limits per band (fixed or updated every 2^u frames, 4.8.2.4)."""

    def __init__(self, pr, updates):
        self.pr = pr
        self.updates = list(updates) if updates is not None else []
        self.pos = 0
        self.a = list(pr.a)
        self.r = list(pr.rr)

    def update(self):
        """Reads the next set of error limits; returns them in entropy coder input order (5.4.2.2.2)."""
        pr = self.pr
        cfg = pr.cfg
        out = []
        if pr.use_abs:
            n = pr.nz if cfg["absolute_error_limit_assignment_method"] else 1
            vals = self.take(n)
            self.a = vals if n > 1 else vals * pr.nz
            out += [("a", v) for v in vals]
        if pr.use_rel:
            n = pr.nz if cfg["relative_error_limit_assignment_method"] else 1
            vals = self.take(n)
            self.r = vals if n > 1 else vals * pr.nz
            out += [("r", v) for v in vals]
        return out

    def take(self, n):
        vals = self.updates[self.pos:self.pos + n]
        assert len(vals) == n, "not enough periodic error limit values"
        self.pos += n
        return vals


def predict(cfg, img, error_limit_updates=None, trace=None):
    """Runs the predictor and quantizer.

    img[z][y][x] holds the samples. Returns (delta, limits) where delta[z][y][x] are the mapped quantizer indices and
    limits[y] is the list of error limit values entered into the entropy coder before frame y (periodic updating).
    trace, when given, is a dict that receives per-sample intermediate values keyed by (z, y, x).
    """
    pr = Params(cfg)
    delta = [[[0] * pr.nx for _ in range(pr.ny)] for _ in range(pr.nz)]

    def quantize(z, y, x, s_hat, s_dbl, m, theta_m):
        s = img[z][y][x]
        assert pr.smin <= s <= pr.smax, (z, y, x, s)
        res = s - s_hat                                             # (40)
        q = sgn(res) * ((abs(res) + m) // (2 * m + 1))              # (41); q = res for m = 0 and for t = 0
        delta[z][y][x] = map_index(q, theta_m, s_dbl)               # (55)
        return q

    limits = run_predictor(pr, error_limit_updates, quantize, trace=trace)
    if trace is not None:
        for (z, y, x), v in trace.items():
            v["delta"] = delta[z][y][x]
    return delta, limits


def run_predictor(pr, error_limit_updates, quantize, trace=None, recon=None, max_error=None):
    """Predictor, quantizer, sample representatives and weight update (4.2 to 4.10) over all samples, by row, then
    column, then band.

    quantize(z, y, x, s_hat, s_dbl, m, theta_m) gives the quantizer index of every sample: the compressor quantizes
    the prediction residual (4.8), the decompressor takes it from the mapped quantizer index (4.11). The values that
    follow from the index are the same in both. Returns limits as predict(); recon and max_error, when given, receive
    the clipped quantizer bin center s'z(t) of every sample (4.9; the sample itself when lossless and for t = 0) and
    its maximum error mz(t) (4.8.2.1).
    """
    nx, ny, nz, d = pr.nx, pr.ny, pr.nz, pr.d
    smin, smax, smid = pr.smin, pr.smax, pr.smid
    om, reg, th = pr.om, pr.reg, pr.theta
    sr = [[[0] * nx for _ in range(ny)] for _ in range(nz)]      # sample representatives s''
    dc = [[[0] * nx for _ in range(ny)] for _ in range(nz)]      # central local differences
    weights = [init_weights(pr, z) for z in range(nz)]
    lim = ErrorLimits(pr, error_limit_updates)
    limits = {}
    for y in range(ny):
        if pr.periodic and y % (1 << pr.u) == 0:
            limits[y] = lim.update()
        for x in range(nx):
            t = y * nx + x
            for z in range(nz):
                pz = pr.pz(z)
                if t == 0:
                    # 4.7.3: double-resolution predicted sample value for t = 0 (the sample of band z - 1, which
                    # equals its representative for t = 0)
                    s_dbl = 2 * sr[z - 1][y][x] if (pr.p > 0 and z > 0) else 2 * smid
                    s_hat = s_dbl >> 1
                    theta_m = min(s_hat - smin, smax - s_hat)      # (56), t = 0
                    q = quantize(z, y, x, s_hat, s_dbl, 0, theta_m)
                    s = s_hat + q                                  # (41), t = 0
                    sr[z][y][x] = s                                # (46), t = 0
                    if recon is not None:
                        recon[z][y][x] = s
                        max_error[z][y][x] = 0
                    if trace is not None:
                        trace[(z, y, x)] = dict(s_hat=s_hat, q=q, m=0)
                    continue
                sigma = local_sum(pr, sr, z, y, x)
                # local difference vector U (4.5.3)
                u = []
                if pr.full:
                    n_ = 4 * sr[z][y - 1][x] - sigma if y > 0 else 0
                    if y > 0:
                        w_ = 4 * (sr[z][y][x - 1] if x > 0 else sr[z][y - 1][x]) - sigma
                        nw_ = 4 * (sr[z][y - 1][x - 1] if x > 0 else sr[z][y - 1][x]) - sigma
                    else:
                        w_ = nw_ = 0
                    u += [n_, w_, nw_]
                for i in range(1, pz + 1):
                    u.append(dc[z - i][y][x])
                wv = weights[z]
                d_pred = sum(wi * ui for wi, ui in zip(wv, u))     # (36); 0 for z = 0 in reduced mode
                s_tilde = clip(mod_r(d_pred + (1 << om) * (sigma - 4 * smid), reg) + (1 << (om + 2)) * smid
                               + (1 << (om + 1)),
                               (1 << (om + 2)) * smin, (1 << (om + 2)) * smax + (1 << (om + 1)))   # (37)
                s_dbl = s_tilde >> (om + 1)                         # (38)
                s_hat = s_dbl >> 1                                  # (39)
                # maximum error (4.8.2.1)
                if pr.fid == 0:
                    m = 0
                elif pr.fid == 1:
                    m = lim.a[z]
                elif pr.fid == 2:
                    m = (lim.r[z] * abs(s_hat)) >> d
                else:
                    m = min(lim.a[z], (lim.r[z] * abs(s_hat)) >> d)
                theta_m = min((s_hat - smin + m) // (2 * m + 1), (smax - s_hat + m) // (2 * m + 1))   # (56)
                q = quantize(z, y, x, s_hat, s_dbl, m, theta_m)      # (41) or (55) inverted
                s_clip = clip(s_hat + q * (2 * m + 1), smin, smax)   # (48)
                if recon is not None:
                    recon[z][y][x] = s_clip
                    max_error[z][y][x] = m
                phi, psi = pr.phi[z], pr.psi[z]
                num = (4 * ((1 << th) - phi) * ((s_clip << om) - ((sgn(q) * m * psi) << om >> th))
                       + phi * s_tilde - (phi << (om + 1)))
                s_rep_dbl = num >> (om + th + 1)                    # (47)
                s_rep = (s_rep_dbl + 1) >> 1                        # (46)
                sr[z][y][x] = s_rep
                dc[z][y][x] = 4 * s_rep - sigma                     # (24)
                # weight update (4.10)
                e = 2 * s_clip - s_dbl                              # (49)
                rho = clip(pr.vmin + ((t - nx) >> pr.tinc_log), pr.vmin, pr.vmax) + d - om   # (50)
                sp = 1 if e >= 0 else -1
                for j in range(len(wv)):
                    if pr.full and j < 3:
                        zo = pr.zeta_star[z]
                    else:
                        zo = pr.zeta[z][j - (3 if pr.full else 0) + 1]
                    wv[j] = clip(wv[j] + weight_increment(sp, u[j], rho + zo), pr.wmin, pr.wmax)
                if trace is not None:
                    trace[(z, y, x)] = dict(sigma=sigma, d_pred=d_pred, s_tilde=s_tilde, s_hat=s_hat, q=q, m=m,
                                            s_rep=s_rep)
    return limits


def weight_increment(sp, dval, shift):
    """floor(1/2 (sgn+(e) 2^-(shift) d + 1)) of (51)-(54), computed exactly."""
    if shift >= 0:
        return (sp * dval + (1 << shift)) >> (shift + 1)
    return (sp * dval * (1 << -shift) + 1) >> 1


def init_weights(pr, z):
    """Initial weight vector W_z(1) (4.6.3)."""
    pz = pr.pz(z)
    cz = pr.cz(z)
    om = pr.om
    if pr.custom_weights:
        q = pr.cfg["large_q"]
        rem = om + 3 - q
        low = ((1 << (rem - 1)) - 1) if rem >= 1 else 0
        return [(lam << rem) + low for lam in pr.lam[z][:cz]]    # (35)
    w = []
    if pr.full:
        w += [0, 0, 0]                                           # (34)
    if pz > 0:
        cur = 7 * (1 << om) // 8                                 # (33)
        w.append(cur)
        for _ in range(2, pz + 1):
            cur = cur // 8
            w.append(cur)
    return w


def local_sum(pr, sr, z, y, x):
    """Local sum sigma_z,y,x (4.4)."""
    nx = pr.nx
    smid = pr.smid
    ls = pr.ls
    if ls == 0:   # wide neighbor-oriented (20)
        if y > 0 and 0 < x < nx - 1:
            return sr[z][y][x - 1] + sr[z][y - 1][x - 1] + sr[z][y - 1][x] + sr[z][y - 1][x + 1]
        if y == 0:
            return 4 * sr[z][y][x - 1]
        if x == 0:
            return 2 * (sr[z][y - 1][x] + sr[z][y - 1][x + 1])
        return sr[z][y][x - 1] + sr[z][y - 1][x - 1] + 2 * sr[z][y - 1][x]
    if ls == 1:   # narrow neighbor-oriented (21)
        if y > 0 and 0 < x < nx - 1:
            return sr[z][y - 1][x - 1] + 2 * sr[z][y - 1][x] + sr[z][y - 1][x + 1]
        if y == 0:
            return 4 * sr[z - 1][y][x - 1] if z > 0 else 4 * smid
        if x == 0:
            return 2 * (sr[z][y - 1][x] + sr[z][y - 1][x + 1])
        return 2 * (sr[z][y - 1][x - 1] + sr[z][y - 1][x])
    if ls == 2:   # wide column-oriented (22)
        return 4 * sr[z][y - 1][x] if y > 0 else 4 * sr[z][y][x - 1]
    # narrow column-oriented (23)
    if y > 0:
        return 4 * sr[z][y - 1][x]
    return 4 * sr[z - 1][y][x - 1] if z > 0 else 4 * smid


def map_index(q, theta_m, s_dbl):
    """Mapped quantizer index (55)."""
    aq = abs(q)
    if aq > theta_m:
        return aq + theta_m
    par = -q if (s_dbl & 1) else q
    if 0 <= par <= theta_m:
        return 2 * aq
    return 2 * aq - 1


# ------------------------------------------------------------------------------------------------
# Entropy coder input order (5.4.2)
# ------------------------------------------------------------------------------------------------
def input_sequence(cfg, delta, limits):
    """Yields ('limit', kind, value) and ('sample', z, t, delta) in entropy coder input order."""
    pr = Params(cfg)
    nx, ny, nz = pr.nx, pr.ny, pr.nz
    if pr.bsq:
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    yield ("sample", z, y * nx + x, delta[z][y][x])
        return
    m = pr.m
    for y in range(ny):
        for kind, v in limits.get(y, []):
            yield ("limit", kind, v)
        for i in range((nz + m - 1) // m):
            for x in range(nx):
                for z in range(i * m, min((i + 1) * m, nz)):
                    yield ("sample", z, y * nx + x, delta[z][y][x])


# ------------------------------------------------------------------------------------------------
# GPO2 codewords (5.4.3.2.2, 5.4.3.3.3.2)
# ------------------------------------------------------------------------------------------------
def gpo2(w, j, k, umax, d):
    u = j >> k
    if u < umax:
        w.put(0, u)
        w.put(1, 1)
        w.put(j & ((1 << k) - 1), k)
    else:
        w.put(0, umax)
        w.put(j, d)


def gpo2_reversed(w, j, k, umax, d):
    u = j >> k
    if u < umax:
        w.put(j & ((1 << k) - 1), k)
        w.put(1, 1)
        w.put(0, u)
    else:
        w.put(j, d)
        w.put(0, umax)


def limit_width(cfg, kind):
    return cfg["large_d_large_a"] if kind == "a" else cfg["large_d_large_r"]


# ------------------------------------------------------------------------------------------------
# Sample-adaptive entropy coder (5.4.3.2)
# ------------------------------------------------------------------------------------------------
def encode_sample_adaptive(cfg, seq, w, header_bits=0, trace=None):
    pr = Params(cfg)
    d = pr.d
    umax, gs, g0 = cfg["large_u_max"], cfg["gamma_star"], cfg["gamma_0"]
    acc = sample_adaptive_initial_accumulators(cfg)
    cnt = [1 << g0] * pr.nz
    last = [None] * pr.nz
    for item in seq:
        if item[0] == "limit":
            w.put(item[2], limit_width(cfg, item[1]))
            continue
        _, z, t, dl = item
        if t == 0:
            w.put(dl, d)                                                   # 5.4.3.2.4.2
            continue
        if t > 1:
            # statistics update with the previous mapped quantizer index of the band (60), (61)
            if cnt[z] < (1 << gs) - 1:
                acc[z] += last[z]
                cnt[z] += 1
            else:
                acc[z] = (acc[z] + last[z] + 1) >> 1
                cnt[z] = (cnt[z] + 1) >> 1
        k = sample_adaptive_k(cnt[z], acc[z], d)
        if trace is not None:
            trace.append((z, t, dl, k))
        gpo2(w, dl, k, umax, d)
        last[z] = dl
    pad_to_word(cfg, w, header_bits)                                       # 5.4.3.2.4.4


def sample_adaptive_initial_accumulators(cfg):
    """Initial accumulator of every band of the sample-adaptive coder (5.4.3.2.3.3)."""
    d, g0 = cfg["large_d"], cfg["gamma_0"]
    acc = []
    for kpp in vec(cfg, "k_prime_prime_vector", cfg["large_n_z"]):
        kp = kpp if kpp <= 30 - d else 2 * kpp + d - 30                    # (59)
        acc.append(((3 * (1 << (kp + 6)) - 49) << g0) >> 7)                # (58), Gamma(1) = 2^g0
    return acc


def sample_adaptive_k(g, a, d):
    """Code index of the sample-adaptive coder for counter g and accumulator a (5.4.3.2.4.3)."""
    if 2 * g > a + ((49 * g) >> 7):
        return 0
    k = 0
    for kk in range(1, d - 1):
        if (g << kk) <= a + ((49 * g) >> 7):
            k = kk
    return k


# ------------------------------------------------------------------------------------------------
# Hybrid entropy coder (5.4.3.3)
# ------------------------------------------------------------------------------------------------
def encode_hybrid(cfg, seq, w, header_bits=0, trace=None):
    pr = Params(cfg)
    d = pr.d
    umax, gs, g0 = cfg["large_u_max"], cfg["gamma_star"], cfg["gamma_0"]
    acc = vec(cfg, "hybrid_initial_accumulator", pr.nz)
    cnt = [1 << g0] * pr.nz
    prefix = [()] * 16
    for item in seq:
        if item[0] == "limit":
            w.put(item[2], limit_width(cfg, item[1]))
            continue
        _, z, t, dl = item
        if t == 0:
            w.put(dl, d)
            continue
        if cnt[z] < (1 << gs) - 1:
            acc[z] += 4 * dl
            cnt[z] += 1
        else:
            w.put(acc[z] & 1, 1)                                           # 5.4.3.3.5.1.2
            acc[z] = (acc[z] + 4 * dl + 1) >> 1
            cnt[z] = (cnt[z] + 1) >> 1
        kind, k = hybrid_code(cnt[z], acc[z], d)
        if kind == "H":
            if trace is not None:
                trace.append((z, t, dl, "H", k))
            gpo2_reversed(w, dl, k, umax, d)
        else:
            i = k
            if trace is not None:
                trace.append((z, t, dl, "L", i))
            if dl > LIMITS[i]:
                sym = "X"
                gpo2_reversed(w, dl - LIMITS[i] - 1, 0, umax, d)
            else:
                sym = dl
            p = prefix[i] + (sym,)
            if p in CODES[i]:
                w.put_bits(CODES[i][p])
                prefix[i] = ()
            else:
                prefix[i] = p
    # compressed image tail (5.4.3.3.5.4)
    for i in range(16):
        w.put_bits(FLUSH[i][prefix[i]])
    for z in range(pr.nz):
        w.put(acc[z], 2 + d + gs)
    w.put(1, 1)
    unit = 8 * cfg["large_b"]
    rem = (header_bits + w.n) % unit
    if rem:
        w.put(0, unit - rem)


def hybrid_code(g, a, d):
    """Coding of a mapped quantizer index by the hybrid coder for counter g and high-resolution accumulator a (the
    statistics after their update with the index, 5.4.3.3.5.1.4): ("H", k) for a high-entropy index and the reversed
    GPO2 code index k (5.4.3.3.5.2), ("L", i) for a low-entropy index and the low-entropy code i (5.4.3.3.5.3.1)."""
    if a * (1 << 14) >= THRESHOLDS[0] * g:
        k = 2
        for kk in range(2, max(d - 2, 2) + 1):
            if (g << (kk + 2)) <= a + ((49 * g) >> 5):
                k = kk
        return "H", k
    i = 0
    for c in range(16):
        if a * (1 << 14) < g * THRESHOLDS[c]:
            i = c
    return "L", i


# ------------------------------------------------------------------------------------------------
# Block-adaptive entropy coder (5.4.3.4, CCSDS 121.0-B-3 with the preprocessor bypassed)
# ------------------------------------------------------------------------------------------------
def block_options(n, restricted):
    """Option identifier width and largest split-sample parameter (CCSDS 121.0-B-3 table 5-1).

    Returns (id_bits, kmax); kmax = -1 when neither FS nor split-sample options exist (restricted, n <= 2).
    """
    if restricted and n <= 2:
        return 1, -1
    if restricted and n <= 4:
        return 2, 1
    if n <= 8:
        return 3, 5
    if n <= 16:
        return 4, 13
    return 5, 29


def fs(w, v):
    """Fundamental sequence codeword: v zeros followed by a one."""
    w.put(0, v)
    w.put(1, 1)


def encode_block_adaptive(cfg, seq, w, header_bits=0, trace=None):
    n = cfg["large_d"]
    jsz = cfg["large_j"]
    restricted = cfg["restricted_code_options_flag"] == 1
    ref = cfg["r"]
    idb, kmax = block_options(n, restricted)
    values = [item[2] if item[0] == "limit" else item[3] for item in seq]
    while len(values) % jsz:                                                # 5.4.3.4.2.7
        values.append(0)
    blocks = [values[i:i + jsz] for i in range(0, len(values), jsz)]
    nblk = len(blocks)
    i = 0
    while i < nblk:
        if not any(blocks[i]):
            # zero-block option: run of all-zeros blocks inside a 64-block segment of a reference interval
            start = (i // ref) * ref
            seg_end = min(start + ((i - start) // 64 + 1) * 64, start + ref, nblk)
            j = i
            while j < seg_end and not any(blocks[j]):
                j += 1
            run = j - i
            w.put(0, idb + 1)
            if j == seg_end and run >= 5:
                fs(w, 4)                                                    # remainder of segment
            else:
                fs(w, run - 1 if run <= 4 else run)
            if trace is not None:
                trace.append(("zero", i, run))
            i = j
            continue
        encode_block(w, blocks[i], n, idb, kmax, trace, i)
        i += 1
    pad_to_word(cfg, w, header_bits)                                        # 5.4.3.4.3.2


def encode_block(w, blk, n, idb, kmax, trace=None, index=0):
    """Single-block options with the selection rules of CCSDS 121.0-B-3 3.7.3 and 3.7.4."""
    jsz = len(blk)
    gam = [((blk[2 * i] + blk[2 * i + 1]) * (blk[2 * i] + blk[2 * i + 1] + 1)) // 2 + blk[2 * i + 1]
           for i in range(jsz // 2)]
    best_len = n * jsz + idb
    best = ("nc", None)
    se_len = sum(g + 1 for g in gam) + idb + 1
    if se_len < best_len:
        best_len, best = se_len, ("se", None)
    for k in range(0, kmax + 1):
        ln = sum((v >> k) + 1 + k for v in blk) + idb
        if ln < best_len:
            best_len, best = ln, ("k", k)
    if trace is not None:
        trace.append((best[0], index, best[1]))
    if best[0] == "nc":
        w.put((1 << idb) - 1, idb)
        for v in blk:
            w.put(v, n)
    elif best[0] == "se":
        w.put(0, idb)
        w.put(1, 1)
        for g in gam:
            fs(w, g)
    else:
        k = best[1]
        w.put(k + 1, idb)
        for v in blk:
            fs(w, v >> k)
        for v in blk:
            w.put(v & ((1 << k) - 1), k)


def pad_to_word(cfg, w, header_bits):
    """Fill bits up to the next output word boundary of the compressed image (header and body)."""
    unit = 8 * cfg["large_b"]
    rem = (header_bits + w.n) % unit
    if rem:
        w.put(0, unit - rem)


# ------------------------------------------------------------------------------------------------
# Largest compressed image
# ------------------------------------------------------------------------------------------------
# Longest output codeword of the low-entropy codes (tables B-1 to B-16) and sum of the longest flush codeword of
# every code (tables B-17 to B-32)
LE_MAX_OUT = max(len(c) for code in CODES for c in code.values())
LE_MAX_FLUSH = sum(max(len(f) for f in flush.values()) for flush in FLUSH)


def max_image_bytes(cfg):
    """Strict upper bound on the size in bytes of the compressed image of any image of the configuration.

    - Header: exactly header(cfg) (5.3).
    - Error limit values of periodic updating: NZ or 1 absolute and NZ or 1 relative values at every update frame,
      DA or DR bits each (4.8.2.4, 5.4.2.2.2; 5.4.3.2.4.1, 5.4.3.3.5.1.1; in the block-adaptive coder they are
      entries of the input sequence).
    - Sample-adaptive coder: the first mapped quantizer index of every band uncoded with D bits (5.4.3.2.4.2); every
      further index a length-limited GPO2 codeword of at most Umax + D bits (5.4.3.2.2.1 and its note).
    - Hybrid coder: the first index of every band with D bits (5.4.3.3.5.1.3); every further index either a reversed
      length-limited GPO2 codeword of at most Umax + D bits (5.4.3.3.3.2.1, 5.4.3.3.5.2) or, in low-entropy
      processing, at most one output codeword of the selected code (5.4.3.3.5.3.5; LE_MAX_OUT bits, tables B-1 to
      B-16) and an escape residual coded with k = 0, at most Umax + D bits (5.4.3.3.5.3.3); one bit per rescaling of
      the statistics of a band (5.4.3.3.5.1.2), counted exactly from the counter, which does not depend on the data
      (5.4.3.3.4.2, 5.4.3.3.4.4); the tail: the longest flush codeword of each of the 16 codes (5.4.3.3.5.4.2,
      LE_MAX_FLUSH bits), the final accumulator of every band with 2 + D + gamma* bits (5.4.3.3.5.4.3) and one bit
      (5.4.3.3.5.4.4).
    - Block-adaptive coder: the input sequence padded with zeros to a multiple of J (5.4.3.4.2.7); every block at most
      the option identifier and J D bits, the length of the no-compression option (CCSDS 121.0-B-3 3.6.1, table
      5-1), because the coder selects the shortest option (3.7.3); a zero-block CDS for k all-zeros blocks (3.5.3,
      3.7.2) has at most identifier + 2 + k bits, less than k blocks without compression.
    - Fill bits up to the next multiple of B bytes (5.4.3.2.4.4, 5.4.3.3.5.4.5, 5.4.3.4.3.2).
    """
    pr = Params(cfg)
    d, nz = pr.d, pr.nz
    t_band = pr.nx * pr.ny
    n_lim, lim_bits = 0, 0
    if pr.periodic:
        frames = (pr.ny + (1 << pr.u) - 1) >> pr.u
        if pr.use_abs:
            n = nz if cfg["absolute_error_limit_assignment_method"] else 1
            n_lim += frames * n
            lim_bits += frames * n * cfg["large_d_large_a"]
        if pr.use_rel:
            n = nz if cfg["relative_error_limit_assignment_method"] else 1
            n_lim += frames * n
            lim_bits += frames * n * cfg["large_d_large_r"]
    umax = cfg["large_u_max"]
    ec = cfg["entropy_coder_type"]
    if ec == 0:
        body = lim_bits + nz * d + nz * (t_band - 1) * (umax + d)
    elif ec == 1:
        gs, g0 = cfg["gamma_star"], cfg["gamma_0"]
        cnt, rescales = 1 << g0, 0
        for _ in range(1, t_band):
            if cnt < (1 << gs) - 1:
                cnt += 1
            else:
                rescales += 1
                cnt = (cnt + 1) >> 1
        per_index = LE_MAX_OUT + umax + d
        body = (lim_bits + nz * d + nz * (t_band - 1) * per_index + nz * rescales + LE_MAX_FLUSH +
                nz * (2 + d + gs) + 1)
    else:
        idb, _ = block_options(d, cfg["restricted_code_options_flag"] == 1)
        jsz = cfg["large_j"]
        blocks = (nz * t_band + n_lim + jsz - 1) // jsz
        body = blocks * (idb + jsz * d)
    unit = 8 * cfg["large_b"]
    bits = 8 * len(header(cfg)) + body
    return (bits + unit - 1) // unit * cfg["large_b"]


# ------------------------------------------------------------------------------------------------
# Compressor
# ------------------------------------------------------------------------------------------------
def compress(cfg, img, error_limit_updates=None):
    """Returns the compressed image (header and body) as bytes."""
    return compress_aborted(cfg, img, None, error_limit_updates)


def compress_aborted(cfg, img, taken, error_limit_updates=None):
    """Returns the compressed image of the first `taken` samples in the input order (all samples for None) and of the
    error limit values before them: the header of the complete image, the codewords of the samples taken with the end
    of the image of the entropy coder after the last one, and the fill bits (an image aborted by an early In_Last,
    CO-FR-03). A decoder that is given the number of samples taken decodes it; the header announces the complete
    image."""
    hdr = header(cfg)
    delta, limits = predict(cfg, img, error_limit_updates)
    seq = input_sequence(cfg, delta, limits)
    if taken is not None:
        seq = _first_samples(seq, taken)
    body = BitWriter()
    hb = 8 * len(hdr)
    ec = cfg["entropy_coder_type"]
    if ec == 0:
        encode_sample_adaptive(cfg, seq, body, header_bits=hb)
    elif ec == 1:
        encode_hybrid(cfg, seq, body, header_bits=hb)
    else:
        encode_block_adaptive(cfg, seq, body, header_bits=hb)
    return hdr + body.to_bytes()


def _first_samples(seq, taken):
    """The items of the input sequence up to and including sample number `taken` (counted from 1)."""
    n = 0
    for item in seq:
        yield item
        if item[0] == "sample":
            n += 1
            if n == taken:
                return


# ------------------------------------------------------------------------------------------------
# SDU payload of ocp_channel
# ------------------------------------------------------------------------------------------------
def sdu_payload(cfg, samples):
    """Samples in the input order as the byte stream of the SDUs of ocp_channel: a big-endian container of
    ceil(D/8) bytes per sample, the value in its D least significant bits (two's complement for signed samples)."""
    d = cfg["large_d"]
    nb = (d + 7) // 8
    mask = (1 << d) - 1
    return b"".join((s & mask).to_bytes(nb, "big") for s in samples)


# ------------------------------------------------------------------------------------------------
# Header parser (for the validation of the model with externally produced compressed images)
# ------------------------------------------------------------------------------------------------
class BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def get(self, width):
        v = 0
        for _ in range(width):
            byte = self.data[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def get_signed(self, width):
        v = self.get(width)
        return v - (1 << width) if v >> (width - 1) else v

    def align(self):
        self.pos = (self.pos + 7) & ~7


# Configuration entries of the per-band tables that the header may leave out (table flags '0', 5.3.3)
TABLE_KEYS = ("large_lambda_vector", "zeta_vector", "phi_vector", "psi_vector", "k_prime_prime_vector")


def parse_header(data, optional_tables=b"", tables=None):
    """Returns (cfg, header length in bytes). A table that the header leaves out is taken from tables, a configuration
    dict (for example the one given to compress(); only TABLE_KEYS are used), when it holds the entry, else read from
    optional_tables (the layout of the CCSDS test data set)."""
    cfg = default_config()
    r = BitReader(data)
    opt = BitReader(optional_tables or b"")

    def outside(key):
        """Values of a table that the header leaves out, from tables; None when they come from optional_tables."""
        if tables is not None and key in tables:
            return list(tables[key])
        return None
    cfg["user_defined_data"] = r.get(8)
    cfg["large_n_x"] = r.get(16) or 65536
    cfg["large_n_y"] = r.get(16) or 65536
    cfg["large_n_z"] = r.get(16) or 65536
    cfg["sample_type"] = r.get(1)
    r.get(1)
    large = r.get(1)
    dmod = r.get(4)
    cfg["large_d"] = dmod + 16 if large else (dmod or 16)
    if large and dmod == 0:
        cfg["large_d"] = 32
    cfg["sample_encoding_order"] = r.get(1)
    m = r.get(16)
    cfg["large_m"] = (m or 65536) if cfg["sample_encoding_order"] == 0 else 0
    r.get(2)
    cfg["large_b"] = r.get(3) or 8
    cfg["entropy_coder_type"] = r.get(2)
    r.get(1)
    cfg["quantizer_fidelity_control_method"] = r.get(2)
    r.get(2)
    nsit = r.get(4)
    nx, ny, nz = cfg["large_n_x"], cfg["large_n_y"], cfg["large_n_z"]
    sits = []
    for _ in range(nsit):
        t = {"type": r.get(2)}
        r.get(2)
        t["purpose"] = r.get(4)
        r.get(1)
        t["structure"] = r.get(2)
        r.get(1)
        t["user_data"] = r.get(4)
        n = {0: 1, 1: nz, 2: nz * nx, 3: ny * nx}[t["structure"]]
        if t["type"] in (0, 1):
            di = r.get(5) or 32
            t["di"] = di
            t["data"] = [r.get_signed(di) if t["type"] == 1 else r.get(di) for _ in range(n)]
        else:
            t["df"] = r.get(5)
            t["de"] = r.get(3) or 8
            t["beta"] = r.get(t["de"])
            t["data"] = [(r.get(1), r.get(t["de"]), r.get(t["df"])) for _ in range(n)]
        r.align()
        sits.append(t)
    cfg["supplementary_information_tables"] = sits
    # predictor primary
    r.get(1)
    cfg["sample_representative_flag"] = r.get(1)
    cfg["large_p"] = r.get(4)
    cfg["prediction_mode"] = r.get(1)
    cfg["weight_exponent_offset_flag"] = r.get(1)
    cfg["local_sum_type"] = r.get(2)
    cfg["large_r"] = r.get(6) or 64
    cfg["large_omega"] = r.get(4) + 4
    cfg["log_two_t_inc"] = r.get(4) + 4
    cfg["v_min"] = r.get(4) - 6
    cfg["v_max"] = r.get(4) - 6
    cfg["weight_exponent_offset_table_flag"] = r.get(1)
    cfg["weight_initialization_method"] = r.get(1)
    cfg["weight_initialization_table_flag"] = r.get(1)
    cfg["large_q"] = r.get(5)
    pr = Params(cfg)
    if cfg["weight_initialization_method"]:
        given = None if cfg["weight_initialization_table_flag"] else outside("large_lambda_vector")
        if given is not None:
            cfg["large_lambda_vector"] = given
        else:
            src = r if cfg["weight_initialization_table_flag"] else opt
            lam = []
            for z in range(nz):
                for _ in range(pr.cz(z)):
                    lam.append(src.get_signed(cfg["large_q"]))
            src.align()
            cfg["large_lambda_vector"] = lam
    if cfg["weight_exponent_offset_flag"]:
        given = None if cfg["weight_exponent_offset_table_flag"] else outside("zeta_vector")
        if given is not None:
            cfg["zeta_vector"] = given
        else:
            src = r if cfg["weight_exponent_offset_table_flag"] else opt
            zv = []
            for z in range(nz):
                for _ in range(pr.pz(z) + (1 if pr.full else 0)):
                    zv.append(src.get_signed(4))
            src.align()
            cfg["zeta_vector"] = zv
    fid = cfg["quantizer_fidelity_control_method"]
    if fid != 0:
        if cfg["sample_encoding_order"] == 0:
            r.get(1)
            cfg["periodic_updating_flag"] = r.get(1)
            r.get(2)
            cfg["u"] = r.get(4)
        for kind, meth, depth, vname in (("abs", "absolute_error_limit_assignment_method", "large_d_large_a",
                                          "a_vector"),
                                         ("rel", "relative_error_limit_assignment_method", "large_d_large_r",
                                          "r_vector")):
            if (kind == "abs" and fid in (1, 3)) or (kind == "rel" and fid in (2, 3)):
                r.get(1)
                cfg[meth] = r.get(1)
                r.get(2)
                cfg[depth] = r.get(4) or 16
                if not cfg["periodic_updating_flag"]:
                    cnt = nz if cfg[meth] else 1
                    cfg[vname] = [r.get(cfg[depth]) for _ in range(cnt)]
                    r.align()
    if cfg["sample_representative_flag"]:
        r.get(5)
        th = r.get(3)
        cfg["large_theta"] = th
        r.get(1)
        cfg["band_varying_damping_flag"] = r.get(1)
        cfg["damping_table_flag"] = r.get(1)
        r.get(1)
        fixed_phi = r.get(4)
        r.get(1)
        cfg["band_varying_offset_flag"] = r.get(1)
        cfg["offset_table_flag"] = r.get(1)
        r.get(1)
        fixed_psi = r.get(4)
        cfg["phi_vector"] = [fixed_phi]
        cfg["psi_vector"] = [fixed_psi]
        if cfg["band_varying_damping_flag"]:
            given = None if cfg["damping_table_flag"] else outside("phi_vector")
            if given is not None:
                cfg["phi_vector"] = given
            else:
                src = r if cfg["damping_table_flag"] else opt
                cfg["phi_vector"] = [src.get(th) for _ in range(nz)]
                src.align()
        if cfg["band_varying_offset_flag"]:
            given = None if cfg["offset_table_flag"] else outside("psi_vector")
            if given is not None:
                cfg["psi_vector"] = given
            else:
                src = r if cfg["offset_table_flag"] else opt
                cfg["psi_vector"] = [src.get(th) for _ in range(nz)]
                src.align()
    ec = cfg["entropy_coder_type"]
    if ec in (0, 1):
        cfg["large_u_max"] = r.get(5) or 32
        cfg["gamma_star"] = r.get(3) + 4
        cfg["gamma_0"] = r.get(3) or 8
        if ec == 0:
            k = r.get(4)
            cfg["accumulator_initialization_table_flag"] = r.get(1)
            if k == 15:
                cfg["band_varying_k_flag"] = 1
                given = None if cfg["accumulator_initialization_table_flag"] else outside("k_prime_prime_vector")
                if given is not None:
                    cfg["k_prime_prime_vector"] = given
                else:
                    src = r if cfg["accumulator_initialization_table_flag"] else opt
                    cfg["k_prime_prime_vector"] = [src.get(4) for _ in range(nz)]
                    src.align()
            else:
                cfg["band_varying_k_flag"] = 0
                cfg["k_prime_prime_vector"] = [k]
        else:
            r.get(5)
    else:
        r.get(1)
        cfg["large_j"] = 8 << r.get(2)
        cfg["restricted_code_options_flag"] = r.get(1)
        cfg["r"] = r.get(12) or 4096
    assert r.pos % 8 == 0
    return cfg, r.pos // 8


# ------------------------------------------------------------------------------------------------
# Decompressor
# ------------------------------------------------------------------------------------------------
class DecodeError(ValueError):
    """The data is not the compressed image of its header (it ends early or its body does not decode)."""


class _Bits:
    """Bit access to a compressed image, most significant bit of every byte first, within the bits lo to hi. Reads
    forward from pos or, with reverse, backward: get(w) then gives the w bits that end at pos, in stream order."""

    def __init__(self, data, pos, lo, hi, reverse=False):
        self.data = data
        self.pos = pos
        self.lo = lo
        self.hi = hi
        self.reverse = reverse

    def bit(self):
        if self.reverse:
            if self.pos <= self.lo:
                raise DecodeError("the compressed image body ends early")
            self.pos -= 1
            p = self.pos
        else:
            if self.pos >= self.hi:
                raise DecodeError("the compressed image ends early")
            p = self.pos
            self.pos += 1
        return (self.data[p >> 3] >> (7 - (p & 7))) & 1

    def get(self, width):
        if width == 0:
            return 0
        if self.reverse:
            p = self.pos - width
            if p < self.lo:
                raise DecodeError("the compressed image body ends early")
            self.pos = p
        else:
            p = self.pos
            if p + width > self.hi:
                raise DecodeError("the compressed image ends early")
            self.pos = p + width
        end = p + width
        first, last = p >> 3, (end + 7) >> 3
        return (int.from_bytes(self.data[first:last], "big") >> (8 * last - end)) & ((1 << width) - 1)

    def zeros(self, limit=None):
        """Number of 'zero' bits before the next 'one', which is taken too; after limit 'zero' bits it stops there."""
        n = 0
        while limit is None or n < limit:
            if self.bit():
                return n
            n += 1
        return n


def coder_input_layout(cfg):
    """The entropy coder input sequence (5.4.2) without its values, as input_sequence() orders it: ("limit", "a" or
    "r") for an error limit value of periodic updating, ("sample", z, t) for a mapped quantizer index."""
    pr = Params(cfg)
    nx, ny, nz = pr.nx, pr.ny, pr.nz
    if pr.bsq:
        return [("sample", z, t) for z in range(nz) for t in range(nx * ny)]
    kinds = []
    if pr.periodic:
        if pr.use_abs:
            kinds += ["a"] * (nz if cfg["absolute_error_limit_assignment_method"] else 1)
        if pr.use_rel:
            kinds += ["r"] * (nz if cfg["relative_error_limit_assignment_method"] else 1)
    m = pr.m
    out = []
    for y in range(ny):
        if pr.periodic and y % (1 << pr.u) == 0:
            out += [("limit", k) for k in kinds]
        for i in range((nz + m - 1) // m):
            for x in range(nx):
                for z in range(i * m, min((i + 1) * m, nz)):
                    out.append(("sample", z, y * nx + x))
    return out


def image_samples(cfg, img):
    """The samples of img[z][y][x] in the input order of the compressor (5.4.2), the order of the raw image files."""
    nx = cfg["large_n_x"]
    return [img[item[1]][item[2] // nx][item[2] % nx] for item in coder_input_layout(cfg) if item[0] == "sample"]


def image_from_samples(cfg, samples):
    """img[z][y][x] from the samples in the input order of the compressor (the inverse of image_samples)."""
    nx, ny, nz = cfg["large_n_x"], cfg["large_n_y"], cfg["large_n_z"]
    img = [[[0] * nx for _ in range(ny)] for _ in range(nz)]
    items = [item for item in coder_input_layout(cfg) if item[0] == "sample"]
    if len(samples) != len(items):
        raise ValueError("{} samples for an image of {}".format(len(samples), len(items)))
    for (_, z, t), s in zip(items, samples):
        img[z][t // nx][t % nx] = s
    return img


def unmap_index(dl, theta_m, s_dbl, low_side):
    """Quantizer index of the mapped quantizer index dl, the inverse of (55). low_side: theta_m is the distance to the
    low end of the sample range, so an index beyond theta_m is positive (4.11)."""
    if dl > 2 * theta_m:
        return dl - theta_m if low_side else theta_m - dl
    a = (dl + 1) >> 1
    q = a if dl % 2 == 0 else -a
    return -q if s_dbl & 1 else q


def _read_gpo2(r, k, umax, d):
    """Length-limited GPO2 codeword (5.4.3.2.2.1); read backward, the reversed codeword (5.4.3.3.3.2.1)."""
    u = r.zeros(umax)
    if u < umax:
        return (u << k) | r.get(k)
    return r.get(d)


def _decode_sample_adaptive(cfg, r, layout):
    pr = Params(cfg)
    d, nz = pr.d, pr.nz
    umax, gs, g0 = cfg["large_u_max"], cfg["gamma_star"], cfg["gamma_0"]
    acc = sample_adaptive_initial_accumulators(cfg)
    cnt = [1 << g0] * nz
    last = [0] * nz
    out = []
    for item in layout:
        if item[0] == "limit":
            out.append(r.get(limit_width(cfg, item[1])))                   # 5.4.3.2.4.1
            continue
        _, z, t = item
        if t == 0:
            out.append(r.get(d))                                           # 5.4.3.2.4.2
            continue
        if t > 1:
            if cnt[z] < (1 << gs) - 1:                                     # (60), (61)
                acc[z] += last[z]
                cnt[z] += 1
            else:
                acc[z] = (acc[z] + last[z] + 1) >> 1
                cnt[z] = (cnt[z] + 1) >> 1
        dl = _read_gpo2(r, sample_adaptive_k(cnt[z], acc[z], d), umax, d)  # 5.4.3.2.4.3
        last[z] = dl
        out.append(dl)
    return out


# Low-entropy codewords and flush words read backward: the reversed codewords form prefix-free codes (5.4.3.3.1)
CODES_REVERSED = [{c[::-1]: p for p, c in code.items()} for code in CODES]
FLUSH_REVERSED = [{f[::-1]: p for p, f in flush.items()} for flush in FLUSH]


def _read_reversed(r, table):
    """The input symbols of the codeword that ends at the read position (table: CODES_REVERSED or FLUSH_REVERSED)."""
    bits = ""
    longest = max(len(b) for b in table)
    while bits not in table:
        if len(bits) >= longest:
            raise DecodeError("no low-entropy codeword ends here")
        bits += "1" if r.bit() else "0"
    return list(table[bits])


def _decode_hybrid(cfg, data, start, layout):
    """The hybrid coder is decoded from the end of the compressed image body (5.4.3.3.1): the tail gives the final
    accumulators and the active prefixes of the low-entropy codes, and the statistics are run backward."""
    pr = Params(cfg)
    d, nz = pr.d, pr.nz
    umax, gs, g0 = cfg["large_u_max"], cfg["gamma_star"], cfg["gamma_0"]
    r = _Bits(data, 8 * len(data), start, 8 * len(data), reverse=True)
    while not r.bit():                                                     # fill bits, 5.4.3.3.5.4.4 and .5
        pass
    acc = [0] * nz
    for z in reversed(range(nz)):
        acc[z] = r.get(2 + d + gs)                                         # 5.4.3.3.5.4.3
    active = [None] * 16
    for i in reversed(range(16)):
        active[i] = _read_reversed(r, FLUSH_REVERSED[i])                   # 5.4.3.3.5.4.2
    # The counter and its rescaling depend on t alone (5.4.3.3.4.2, 5.4.3.3.4.4)
    tmax = pr.nx * pr.ny
    count = [0] * tmax
    rescaled = [False] * tmax
    cnt = 1 << g0
    for t in range(1, tmax):
        if cnt < (1 << gs) - 1:
            cnt += 1
        else:
            rescaled[t] = True
            cnt = (cnt + 1) >> 1
        count[t] = cnt
    out = [0] * len(layout)
    for n in range(len(layout) - 1, -1, -1):
        item = layout[n]
        if item[0] == "limit":
            out[n] = r.get(limit_width(cfg, item[1]))                      # 5.4.3.3.5.1.1
            continue
        _, z, t = item
        if t == 0:
            out[n] = r.get(d)                                              # 5.4.3.3.5.1.3
            continue
        # the code follows from the statistics after their update with the index (5.4.3.3.5.1.4)
        kind, k = hybrid_code(count[t], acc[z], d)
        if kind == "H":
            dl = _read_gpo2(r, k, umax, d)                                 # 5.4.3.3.5.2
        else:
            if not active[k]:
                active[k] = _read_reversed(r, CODES_REVERSED[k])           # 5.4.3.3.5.3.5
            sym = active[k].pop()
            dl = _read_gpo2(r, 0, umax, d) + LIMITS[k] + 1 if sym == "X" else sym    # 5.4.3.3.5.3.3
        # the statistics before the update: a rescaling wrote the bit it dropped (5.4.3.3.5.1.2)
        if rescaled[t]:
            acc[z] = 2 * acc[z] - r.get(1) - 4 * dl
        else:
            acc[z] -= 4 * dl
        out[n] = dl
    if r.pos != start or any(active):
        raise DecodeError("the compressed image body does not decode to the image of its header")
    return out


def _decode_block_adaptive(cfg, r, count):
    """CCSDS 121.0-B-3 with the preprocessor bypassed, as encode_block_adaptive()."""
    n = cfg["large_d"]
    jsz = cfg["large_j"]
    ref = cfg["r"]
    idb, _ = block_options(n, cfg["restricted_code_options_flag"] == 1)
    nblk = (count + jsz - 1) // jsz
    values = []
    i = 0
    while i < nblk:
        opt = r.get(idb)
        if opt == 0:
            if not r.bit():
                # zero-block option: a run of all-zeros blocks within a segment of 64 blocks of a reference interval
                v = r.zeros()
                start = (i // ref) * ref
                seg_end = min(start + ((i - start) // 64 + 1) * 64, start + ref, nblk)
                run = seg_end - i if v == 4 else v + 1 if v < 4 else v
                if i + run > seg_end:
                    raise DecodeError("a zero-block run crosses its segment")
                values += [0] * (run * jsz)
                i += run
                continue
            # second extension option: pairs from gamma = (a + b)(a + b + 1) / 2 + b
            for _ in range(jsz // 2):
                g = r.zeros()
                s = (math.isqrt(8 * g + 1) - 1) // 2
                b = g - s * (s + 1) // 2
                values += [s - b, b]
        elif opt == (1 << idb) - 1:
            values += [r.get(n) for _ in range(jsz)]                       # no compression
        else:
            k = opt - 1                                                    # sample splitting
            high = [r.zeros() for _ in range(jsz)]
            values += [(h << k) | r.get(k) for h in high]
        i += 1
    return values[:count]


def decompress(data, optional_tables=None, tables=None):
    """Decompresses a compressed image (header and body, 5.3 and 5.4); returns (cfg, img, max_error).

    cfg is the configuration of the header (parse_header(); a table that the header leaves out is taken from tables, a
    configuration dict such as the one given to compress(), or from optional_tables). img[z][y][x] holds the clipped
    quantizer bin centers s'z(t), which differ from the samples of the compressed image by at most the maximum error
    mz(t) and equal them under lossless compression (4.1, 4.8.2.1, 4.9); max_error[z][y][x] holds mz(t).

    With the hybrid coder data must end with the compressed image, which is decoded from its end (5.4.3.3.1); with the
    other coders bytes after the compressed image are ignored. Raises DecodeError when the data cannot be the
    compressed image of its header.
    """
    try:
        cfg, hlen = parse_header(data, optional_tables, tables)
    except IndexError:
        raise DecodeError("the header ends early, or a table that it leaves out is not given") from None
    pr = Params(cfg)
    layout = coder_input_layout(cfg)
    start, end = 8 * hlen, 8 * len(data)
    ec = cfg["entropy_coder_type"]
    if ec == 0:
        values = _decode_sample_adaptive(cfg, _Bits(data, start, start, end), layout)
    elif ec == 1:
        values = _decode_hybrid(cfg, data, start, layout)
    else:
        values = _decode_block_adaptive(cfg, _Bits(data, start, start, end), len(layout))
    nx, ny, nz = pr.nx, pr.ny, pr.nz
    delta = [[[0] * nx for _ in range(ny)] for _ in range(nz)]
    updates = []
    for item, v in zip(layout, values):
        if item[0] == "limit":
            updates.append(v)
        else:
            delta[item[1]][item[2] // nx][item[2] % nx] = v
    img = [[[0] * nx for _ in range(ny)] for _ in range(nz)]
    max_error = [[[0] * nx for _ in range(ny)] for _ in range(nz)]
    smin = pr.smin

    def quantize(z, y, x, s_hat, s_dbl, m, theta_m):
        return unmap_index(delta[z][y][x], theta_m, s_dbl, theta_m == (s_hat - smin + m) // (2 * m + 1))

    run_predictor(pr, updates, quantize, recon=img, max_error=max_error)
    return cfg, img, max_error
