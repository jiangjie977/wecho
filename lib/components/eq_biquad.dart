/// Copyright (C) 2026 qumolangmo
///
/// This file is part of Wecho.
///
/// Wecho is free software: you can redistribute it and/or modify
/// it under the terms of the GNU General Public License as published by
/// the Free Software Foundation, either version 3 of the License, or
/// (at your option) any later version.
///
/// Wecho is distributed in the hope that it will be useful,
/// but WITHOUT ANY WARRANTY; without even the implied warranty of
/// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
/// GNU General Public License for more details.
///
/// You should have received a copy of the GNU General Public License
/// along with Wecho.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:math';
import '../models/audio_config.dart';

class BiquadCoeffs {
  final double b0, b1, b2, a1, a2;
  const BiquadCoeffs(this.b0, this.b1, this.b2, this.a1, this.a2);

  double magnitudeAt(double w) {
    final cosw = cos(w);
    final sinw = sin(w);
    final cos2w = cos(2 * w);
    final sin2w = sin(2 * w);

    final numRe = b0 + b1 * cosw + b2 * cos2w;
    final numIm = -(b1 * sinw + b2 * sin2w);

    final denRe = 1 - a1 * cosw - a2 * cos2w;
    final denIm = a1 * sinw + a2 * sin2w;

    final numMag2 = numRe * numRe + numIm * numIm;
    final denMag2 = denRe * denRe + denIm * denIm;
    if (denMag2 == 0) return 0;
    return sqrt(numMag2 / denMag2);
  }

  double dbAt(double freq, int sampleRate) {
    final w = 2 * pi * freq / sampleRate;
    final mag = magnitudeAt(w);
    if (mag <= 0) return -120;
    return 20 * log(mag) / ln10;
  }

  factory BiquadCoeffs.peak(double freq, double q, double gain, int sampleRate) {
    final w = 2 * pi * freq / sampleRate;
    final cosw = cos(w);
    final sinw = sin(w);
    final A = pow(10.0, gain / 40.0).toDouble();
    final alpha = sinw / (2 * q);
    final a0 = 1 + alpha / A;
    final b0 = (1 + alpha * A) / a0;
    final b1 = (-2 * cosw) / a0;
    final b2 = (1 - alpha * A) / a0;
    final a1 = -(-2 * cosw) / a0; // negated
    final a2 = -(1 - alpha / A) / a0;
    return BiquadCoeffs(b0, b1, b2, a1, a2);
  }

  factory BiquadCoeffs.lowShelf(double freq, double q, double gain, int sampleRate) {
    final w = 2 * pi * freq / sampleRate;
    final cosw = cos(w);
    final sinw = sin(w);
    final A = pow(10.0, gain / 40.0).toDouble();
    final alpha = sinw / (2 * q);
    final beta = 2 * sqrt(A) * alpha;
    final ap = A + 1;
    final am = A - 1;
    final a0 = ap + am * cosw + beta;
    final b0 = A * (ap - am * cosw + beta) / a0;
    final b1 = 2 * A * (am - ap * cosw) / a0;
    final b2 = A * (ap - am * cosw - beta) / a0;
    final a1 = -(-2 * (am + ap * cosw)) / a0;
    final a2 = -((ap + am * cosw - beta) / a0);
    return BiquadCoeffs(b0, b1, b2, a1, a2);
  }

  factory BiquadCoeffs.highShelf(double freq, double q, double gain, int sampleRate) {
    final w = 2 * pi * freq / sampleRate;
    final cosw = cos(w);
    final sinw = sin(w);
    final A = pow(10.0, gain / 40.0).toDouble();
    final alpha = sinw / (2 * q);
    final beta = 2 * sqrt(A) * alpha;
    final ap = A + 1;
    final am = A - 1;
    final a0 = ap - am * cosw + beta;
    final b0 = A * (ap + am * cosw + beta) / a0;
    final b1 = -2 * A * (am + ap * cosw) / a0;
    final b2 = A * (ap + am * cosw - beta) / a0;
    final a1 = -(2 * (am - ap * cosw)) / a0;
    final a2 = -((ap - am * cosw - beta) / a0);
    return BiquadCoeffs(b0, b1, b2, a1, a2);
  }

  static BiquadCoeffs forFilter(EQFilterType type, double freq, double q, double gain, int sampleRate) {
    switch (type) {
      case EQFilterType.pk: return BiquadCoeffs.peak(freq, q, gain, sampleRate);
      case EQFilterType.lsc: return BiquadCoeffs.lowShelf(freq, q, gain, sampleRate);
      case EQFilterType.hsc: return BiquadCoeffs.highShelf(freq, q, gain, sampleRate);
    }
  }
}

class EqResponse {
  static List<double> freqAxis(double fMin, double fMax, int points) {
    final logMin = log(fMin);
    final logMax = log(fMax);
    final step = (logMax - logMin) / (points - 1);
    return List.generate(points, (i) => exp(logMin + step * i));
  }

  static List<double> responseDb(List<EQFilter> filters, double preamp,
      List<double> freqs, int sampleRate) {

    final coeffs = filters
        .where((f) => f.enabled)
        .map((f) => BiquadCoeffs.forFilter(f.type, f.fc.toDouble(), f.q, f.gain, sampleRate))
        .toList();
    final result = List<double>.filled(freqs.length, preamp);
    for (var i = 0; i < freqs.length; i++) {
      for (final c in coeffs) {
        result[i] += c.dbAt(freqs[i], sampleRate);
      }
    }
    return result;
  }
}

class EqLsqFit {
  static List<double> fitGains({
    required int numBands,
    required List<double> freqs,
    required List<double> targetDb,
    required int sampleRate,
    double fMin = 20,
    double fMax = 20000,
    double q = 1.0,
  }) {

    final logMin = log(fMin);
    final logMax = log(fMax);
    final fc = List.generate(numBands,
        (i) => exp(logMin + (logMax - logMin) * i / (numBands - 1)));

    final m = freqs.length;
    final n = numBands;
    // Precompute each filter's unit-gain dB response across freqs.
    final unitDb = List.generate(n, (j) {
      final c = BiquadCoeffs.peak(fc[j], q, 1.0, sampleRate);
      return List.generate(m, (i) => c.dbAt(freqs[i], sampleRate));
    });

    // Normal equations: AtA (n x n) and Atb (n).
    final ata = List.generate(n, (_) => List<double>.filled(n, 0));
    final atb = List<double>.filled(n, 0);
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < n; j++) {
        atb[j] += unitDb[j][i] * targetDb[i];
        for (var k = j; k < n; k++) {
          ata[j][k] += unitDb[j][i] * unitDb[k][i];
        }
      }
    }
    // Symmetrize.
    for (var j = 0; j < n; j++) {
      for (var k = 0; k < j; k++) {
        ata[j][k] = ata[k][j];
      }
    }

    // Solve via Gaussian elimination with partial pivoting.
    final x = atb.toList();
    final aug = List.generate(n, (j) => [...ata[j], x[j]]);
    for (var col = 0; col < n; col++) {
      // Pivot.
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (aug[r][col].abs() > aug[pivot][col].abs()) pivot = r;
      }
      if (pivot != col) {
        final tmp = aug[pivot]; aug[pivot] = aug[col]; aug[col] = tmp;
      }
      final diag = aug[col][col];
      if (diag.abs() < 1e-12) continue;
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final factor = aug[r][col] / diag;
        for (var c = col; c <= n; c++) {
          aug[r][c] -= factor * aug[col][c];
        }
      }
    }
    final gains = List<double>.filled(n, 0);
    for (var j = 0; j < n; j++) {
      final diag = aug[j][j];
      gains[j] = diag.abs() < 1e-12 ? 0 : aug[j][n] / diag;
    }
    return gains;
  }

  static List<double?> fitGainsSubset({
    required List<EQFilter> allFilters,
    required List<int> movableIndices,
    required List<double> freqs,
    required List<double> targetDb,
    required int sampleRate,
    double q = 1.0,
  }) {
    final m = freqs.length;
    final n = allFilters.length;
    final movable = movableIndices.toList()..sort();
    final nMov = movable.length;

    final unitDb = List.generate(nMov, (mj) {
      final f = allFilters[movable[mj]];
      // Use the filter's actual type (peak/lowShelf/highShelf) so the unit
      // response matches the filter shape. Using peak for shelf filters made
      // the passband unit response ~0 dB, which inflated fitted gains and
      // caused erratic drag sensitivity inside shelf passbands.
      final c = BiquadCoeffs.forFilter(
          f.type, f.fc.toDouble(), f.q.toDouble() == 0 ? q : f.q.toDouble(),
          1.0, sampleRate);
      return List.generate(m, (i) => c.dbAt(freqs[i], sampleRate));
    });

    final b = List<double>.from(targetDb);
    for (var j = 0; j < n; j++) {
      if (movable.contains(j)) continue;
      final f = allFilters[j];
      final c = BiquadCoeffs.forFilter(
          f.type, f.fc.toDouble(), f.q.toDouble() == 0 ? q : f.q.toDouble(),
          f.gain.toDouble(), sampleRate);
      for (var i = 0; i < m; i++) {
        b[i] -= c.dbAt(freqs[i], sampleRate);
      }
    }

    // Normal equations for the movable filters only.
    final ata = List.generate(nMov, (_) => List<double>.filled(nMov, 0));
    final atb = List<double>.filled(nMov, 0);
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < nMov; j++) {
        atb[j] += unitDb[j][i] * b[i];
        for (var k = j; k < nMov; k++) {
          ata[j][k] += unitDb[j][i] * unitDb[k][i];
        }
      }
    }
    for (var j = 0; j < nMov; j++) {
      for (var k = 0; k < j; k++) {
        ata[j][k] = ata[k][j];
      }
    }

    final aug = List.generate(nMov, (j) => [...ata[j], atb[j]]);
    for (var col = 0; col < nMov; col++) {
      var pivot = col;
      for (var r = col + 1; r < nMov; r++) {
        if (aug[r][col].abs() > aug[pivot][col].abs()) pivot = r;
      }
      if (pivot != col) {
        final tmp = aug[pivot]; aug[pivot] = aug[col]; aug[col] = tmp;
      }
      final diag = aug[col][col];
      if (diag.abs() < 1e-12) continue;
      for (var r = 0; r < nMov; r++) {
        if (r == col) continue;
        final factor = aug[r][col] / diag;
        for (var c = col; c <= nMov; c++) {
          aug[r][c] -= factor * aug[col][c];
        }
      }
    }

    final result = List<double?>.filled(n, null);
    for (var mj = 0; mj < nMov; mj++) {
      final diag = aug[mj][mj];
      result[movable[mj]] = diag.abs() < 1e-12 ? 0.0 : aug[mj][nMov] / diag;
    }
    return result;
  }
}
