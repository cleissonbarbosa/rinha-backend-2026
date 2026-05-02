const std = @import("std");

const MaxAmount: f64 = 10_000.0;
const MaxInstallments: f64 = 12.0;
const AmountVsAvgRatio: f64 = 10.0;
const MaxTxCount24h: f64 = 20.0;
const MaxKm: f64 = 1_000.0;

const SafeAmountVsAvg: f64 = 0.055;

fn clamp01(x: f64) f64 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

fn round4(x: f64) f64 {
    if (x < 0.0) return x;
    return @floor(x * 10_000.0 + 0.5) / 10_000.0;
}

fn mccRisk(code: c_int) f64 {
    return switch (code) {
        5411 => 0.15,
        5812 => 0.30,
        5912 => 0.20,
        5944 => 0.45,
        7801 => 0.80,
        7802 => 0.75,
        7995 => 0.85,
        4511 => 0.35,
        5311 => 0.25,
        5999 => 0.50,
        else => 0.50,
    };
}

export fn fraud_score_core(
    amount: f64,
    installments: c_int,
    customer_avg_amount: f64,
    tx_count_24h: c_int,
    merchant_known: c_int,
    mcc_code: c_int,
    km_from_home: f64,
) c_int {
    const avg = if (customer_avg_amount > 0.0) customer_avg_amount else 0.01;

    const v0 = round4(clamp01(amount / MaxAmount));
    const v1 = round4(clamp01(@as(f64, @floatFromInt(installments)) / MaxInstallments));
    const v2 = round4(clamp01((amount / avg) / AmountVsAvgRatio));
    const v7 = round4(clamp01(km_from_home / MaxKm));
    const v8 = round4(clamp01(@as(f64, @floatFromInt(tx_count_24h)) / MaxTxCount24h));
    const v11: f64 = if (merchant_known != 0) 0.0 else 1.0;
    const v12 = mccRisk(mcc_code);

    if (v2 <= SafeAmountVsAvg) return 0;

    const risk =
        v2 * 0.46 +
        v0 * 0.16 +
        v1 * 0.08 +
        v7 * 0.13 +
        v8 * 0.08 +
        v11 * 0.04 +
        v12 * 0.05;

    if (risk >= 0.90) return 10;
    if (risk >= 0.52) return 8;
    return 6;
}

