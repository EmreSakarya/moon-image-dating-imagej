// Moon_Date_Estimator.ijm
//
// NEM469 Homework 1: estimates the date and hour of an undated Moon image
// from the luminance (mean gray value) of Moon images with known dates.
//
// Method
//  1. Each image is converted to 8-bit with weighted RGB conversion
//     (Y = 0.299R + 0.587G + 0.114B) and its mean gray value is measured on
//     the same ROI for every image: the whole frame (Edit > Selection > Select All).
//  2. The Earth-Moon distance changes during the month, so the apparent Moon
//     radius R changes too and the whole-frame mean scales with R^2. R is found
//     by fitting a circle to the sunlit limb and the mean is (optionally)
//     corrected to a common radius.
//  3. The dated values are fitted with the phase model
//        L(t) = a + b * F(theta),   theta = 2*PI*(t - t0) / P
//     theta = Sun-Moon elongation, P = 29.530589 d (synodic month), t0 = time
//     of new Moon, a = offset, b = brightness scale. F is the phase law:
//        Lambert sphere (default): F = (sin(al) + (PI - al)*cos(al)) / PI, al = PI - theta
//        illuminated fraction:     F = (1 - cos(theta)) / 2
//     Three unknowns (a, b, t0) -> at least 3 dated images.
//  4. Every luminance value occurs twice per month (waxing and waning). The
//     branch is decided by the lit side of the disk: lit on the right = waxing
//     (northern-hemisphere view, north up).
//  5. The phase itself is measured by counting pixels, which does not depend on
//     how bright the lit surface looks: k = (number of sunlit pixels) / (pi R^2)
//     is the illuminated fraction, theta = acos(1 - 2k). The dim band along the
//     terminator that falls below the threshold has a projected area proportional
//     to sin(theta), so it shifts every phase by about the same angle; that
//     common shift cancels in the interpolation below.
//  6. The phases of the dated images are unwrapped along time and the unknown is
//     placed by interpolating its phase between the two dated images that
//     bracket it (the luminance curve picks the right month). The luminance-only
//     estimate, the time resolution and a leave-one-out test are reported too.
//
// Installation: copy this file to Fiji.app/plugins (or ImageJ/plugins), restart,
// then run Plugins > Moon Date Estimator and choose the image folder.
// Batch use:  java -jar ij.jar -batch Moon_Date_Estimator.ijm "dir=C:/data/Moon Dates/|year=2026"
//
// File names must contain day, month name and time, e.g. 3_October_02_00AM.jpg
// or 31_October_12AM.jpg. The undated image must have "Unknown" in its name.

requires("1.52a");

var P = 29.530589;      // mean synodic month (days)
var YEAR = 2026;        // year used when a file name has no year
var LIT_T = 25;         // 8-bit gray level from which a pixel counts as sunlit (histogram valley
                        // between the dark side, about 3-24, and the sunlit surface)
var BG_T = 3;           // 8-bit gray level below which a pixel is sky background
var LAW = 0;            // phase law: 0 = Lambert sphere, 1 = illuminated fraction
var SIG_K = 0.01;       // uncertainty of the lit-area fraction at quarter phase (scales with sin(theta))
var INTERACTIVE = true;
var SUMMARY = "";

// set by fitModel()
var FA = 0; var FB = 0; var FT0 = 0; var FSSE = 0; var FN = 0;
// set by measureMoon()
var M_MEAN = 0; var M_R = 0; var M_DX = 0; var M_K = 0;
// set by phaseTime(): bracketing dated images (-1 = none) and time uncertainty (days)
var PT_A = -1; var PT_B = -1; var PT_SIG = NaN;
// set by fitCircle()
var C_X = 0; var C_Y = 0; var C_R = 0;

// ---------------------------------------------------------------- settings
dir = ""; outDir = ""; correct = true; saveFiles = true;
arg = getArgument();
if (arg != "") {
	INTERACTIVE = false;
	opts = split(arg, "|");
	for (i = 0; i < opts.length; i++) {
		eq = indexOf(opts[i], "=");
		if (eq < 0) continue;
		key = toLowerCase(substring(opts[i], 0, eq));
		val = substring(opts[i], eq + 1);
		if (key == "dir") dir = val;
		else if (key == "out") outDir = val;
		else if (key == "year") YEAR = parseInt(val);
		else if (key == "period") P = parseFloat(val);
		else if (key == "lit") LIT_T = parseInt(val);
		else if (key == "law") LAW = (startsWith(toLowerCase(val), "cos") || startsWith(toLowerCase(val), "ill"));
		else if (key == "correct") correct = (toLowerCase(val) == "true");
		else if (key == "save") saveFiles = (toLowerCase(val) == "true");
	}
} else {
	dir = getDirectory("Choose the folder with the Moon images");
	Dialog.create("Moon Date Estimator");
	Dialog.addNumber("Year of the images:", YEAR);
	Dialog.addNumber("Synodic month (days):", P, 6, 10, "");
	Dialog.addNumber("Lit-pixel threshold (0-255):", LIT_T);
	Dialog.addChoice("Phase law:", newArray("Lambert sphere", "Illuminated fraction (cosine)"));
	Dialog.addCheckbox("Correct luminance for apparent Moon size", correct);
	Dialog.addCheckbox("Save table, plot and summary (Moon_results folder)", saveFiles);
	Dialog.show();
	YEAR = Dialog.getNumber();
	P = Dialog.getNumber();
	LIT_T = Dialog.getNumber();
	LAW = (Dialog.getChoice() != "Lambert sphere");
	correct = Dialog.getCheckbox();
	saveFiles = Dialog.getCheckbox();
}
if (dir == "") exit("No image folder given.");
if (!endsWith(dir, "/") && !endsWith(dir, "\\")) dir = dir + File.separator;
if (outDir == "") outDir = dir + "Moon_results" + File.separator;
if (!endsWith(outDir, "/") && !endsWith(outDir, "\\")) outDir = outDir + File.separator;

// ---------------------------------------------------------------- image list and dates
list = getFileList(dir);
names = newArray(0);
times = newArray(0);    // days since 1 January YEAR 00:00, NaN = undated
for (i = 0; i < list.length; i++) {
	lower = toLowerCase(list[i]);
	if (!matches(lower, ".*\\.(jpg|jpeg|png|tif|tiff|bmp|gif)")) continue;
	t = NaN;
	if (indexOf(lower, "unknown") < 0 && indexOf(lower, "undated") < 0) {
		t = parseFileTime(list[i]);
		if (isNaN(t)) t = askTime(list[i]);
		if (t == -1e30) continue;
	}
	names = Array.concat(names, list[i]);
	times = Array.concat(times, t);
}
n = names.length;
nd = 0;
for (i = 0; i < n; i++) if (!isNaN(times[i])) nd++;
if (nd < 3) exit("At least 3 dated images are needed (found " + nd + "):\nthe model has three unknowns (offset, scale and time of new Moon).");
if (nd == n) exit("No undated image found. Put \"Unknown\" in its file name.");

// ---------------------------------------------------------------- measurement
setBatchMode(true);
run("Conversions...", "scale weighted");
mean = newArray(n); radius = newArray(n); dx = newArray(n); kpix = newArray(n);
w0 = 0; h0 = 0; sameSize = true;
for (i = 0; i < n; i++) {
	showProgress(i, n);
	open(dir + names[i]);
	if (i == 0) { w0 = getWidth(); h0 = getHeight(); }
	else if (getWidth() != w0 || getHeight() != h0) sameSize = false;
	measureMoon();
	mean[i] = M_MEAN; radius[i] = M_R; dx[i] = M_DX; kpix[i] = M_K;
	close();
}

// phase of every image from pixel counting
ph = newArray(n); sg = newArray(n);
for (i = 0; i < n; i++) {
	ph[i] = pixelPhase(kpix[i], dx[i]);
	sg[i] = phaseSigma(kpix[i], ph[i]);
}

rRef = 0;
for (i = 0; i < n; i++) if (!isNaN(times[i])) rRef += radius[i];
rRef /= nd;
lum = newArray(n);
for (i = 0; i < n; i++) {
	if (correct) lum[i] = mean[i] * pow(rRef / radius[i], 2);
	else lum[i] = mean[i];
}

// ---------------------------------------------------------------- model fit and estimates
use = newArray(n);
for (i = 0; i < n; i++) use[i] = !isNaN(times[i]);

// leave-one-out test: date every dated image from the others. The error is taken
// modulo one synodic month: the phase alone cannot tell which month it is.
looErr = newArray(n);
looSq = 0; looN = 0; looMonth = 0;
for (j = 0; j < n; j++) {
	looErr[j] = NaN;
	if (!use[j] || nd < 4) continue;
	use2 = Array.copy(use);
	use2[j] = 0;
	fitModel(times, lum, use2);
	ref = estimateLocal(times, lum, use2, lum[j], sideOf(dx[j]));
	if (isNaN(ref)) ref = estimateGlobal(lum[j], sideOf(dx[j]), times, use2);
	e = phaseTime(times, ph, sg, use2, ph[j], sg[j], ref) - times[j];
	if (abs(e) > P / 2) looMonth++;
	looErr[j] = 24 * (e - P * round(e / P));
	looSq += looErr[j] * looErr[j];
	looN++;
}

fitModel(times, lum, use);
sigma = NaN;
if (nd > 3) sigma = sqrt(FSSE / (nd - 3));

estL = newArray(n); estLum = newArray(n); estAlt = newArray(n); resH = newArray(n);
ancA = newArray(n); ancB = newArray(n);
for (i = 0; i < n; i++) {
	estL[i] = NaN; estLum[i] = NaN; estAlt[i] = NaN; resH[i] = NaN; ancA[i] = -1; ancB[i] = -1;
	if (use[i]) continue;
	side = sideOf(dx[i]);
	if (side == 0) side = 1;
	// luminance curve: rough time, used to pick the month
	estLum[i] = estimateLocal(times, lum, use, lum[i], side);
	if (isNaN(estLum[i])) estLum[i] = estimateGlobal(lum[i], side, times, use);
	// pixel-counting phase: final estimate
	estL[i] = phaseTime(times, ph, sg, use, ph[i], sg[i], estLum[i]);
	resH[i] = 24 * PT_SIG; ancA[i] = PT_A; ancB[i] = PT_B;
	if (sideOf(dx[i]) == 0) estAlt[i] = phaseTime(times, ph, sg, use, 2 * PI - ph[i], sg[i], estLum[i]);
}

// ---------------------------------------------------------------- results table
run("Clear Results");
sortKey = newArray(n);
for (i = 0; i < n; i++) { sortKey[i] = times[i]; if (isNaN(times[i])) sortKey[i] = 1e9 + i; }
order = Array.rankPositions(sortKey);
for (q = 0; q < n; q++) {
	i = order[q];
	setResult("Image", q, names[i]);
	if (use[i]) { txt = formatTime(times[i]); setResult("Date/time", q, txt); }
	else setResult("Date/time", q, "Unknown");
	setResult("Mean gray value (whole image)", q, mean[i]);
	setResult("Moon radius (px)", q, radius[i]);
	setResult("Size-corrected mean", q, lum[i]);
	txt = sideText(dx[i]);
	setResult("Lit side", q, txt);
	if (use[i]) {
		model = FA + FB * lawAt(times[i], FT0);
		setResult("Model", q, model);
		setResult("Residual", q, lum[i] - model);
		setResult("Leave-one-out error (h)", q, looErr[i]);
		setResult("Estimated date/time", q, "");
	} else {
		setResult("Model", q, NaN);
		setResult("Residual", q, NaN);
		setResult("Leave-one-out error (h)", q, NaN);
		txt = formatTime(estL[i]);
		setResult("Estimated date/time", q, txt);
	}
}
updateResults();

// ---------------------------------------------------------------- summary
if (INTERACTIVE) print("\\Clear");
out("Moon Date Estimator: " + nd + " dated image(s), " + (n - nd) + " undated");
out("Measurement: whole image ROI (" + w0 + " x " + h0 + " px), 8-bit weighted RGB, mean gray value");
if (!sameSize) out("WARNING: the images do not all have the same size, so the ROI is not identical.");
if (correct) out("Size correction: L = mean * (R_ref / R)^2, R_ref = " + d2s(rRef, 1) + " px");
else out("Size correction: off (L = mean gray value)");
if (LAW == 0) out("Model: L(t) = a + b * F(theta), F = Lambert-sphere phase law, theta = 2*pi*(t - t0)/P,  P = " + d2s(P, 6) + " d");
else out("Model: L(t) = a + b * (1 - cos(theta))/2 (illuminated fraction), theta = 2*pi*(t - t0)/P,  P = " + d2s(P, 6) + " d");
out("  a = " + d2s(FA, 3) + ",  b = " + d2s(FB, 3) + ",  RMS residual = " + d2s(sigma, 3) + " gray levels (" + nd + " points, 3 parameters)");
tMid = 0;
for (i = 0; i < n; i++) if (use[i]) tMid += times[i] / nd;
tNew = FT0 + P * round((tMid - FT0) / P);
txt = formatTime(tNew);
out("  new Moon from fit:  " + txt);
txt = formatTime(tNew + P / 2);
out("  full Moon from fit: " + txt);
out("Phase: sunlit pixels (gray >= " + LIT_T + ") counted and divided by pi R^2 (R from a circle fit to the sunlit limb)");
if (looN > 0) {
	out("Leave-one-out test (each dated image dated from the other " + (nd - 1) + "): RMS error = " + d2s(sqrt(looSq / looN), 1) + " h");
	if (looMonth > 0) out("  " + looMonth + " image(s) landed in the wrong month (same phase one synodic month apart); errors are given modulo one month.");
}
for (i = 0; i < n; i++) {
	if (use[i]) continue;
	txt = sideText(dx[i]);
	out("");
	out("" + names[i] + ":  L = " + d2s(lum[i], 3) + ",  lit side: " + txt);
	el = ph[i];
	if (el > PI) el = 2 * PI - el;
	out("  lit area = " + d2s(100 * kpix[i], 1) + " % of the disk -> illuminated fraction " + d2s((1 - cos(el)) / 2, 3) + ", phase angle " + d2s(180 - el * 180 / PI, 1) + " deg");
	txt = formatTime(estL[i]);
	out("  ESTIMATE: " + txt + "   +/- " + d2s(resH[i], 1) + " h");
	if (ancB[i] >= 0) {
		ta = formatTime(times[ancA[i]]);
		tb = formatTime(times[ancB[i]]);
		out("    phase interpolated between the dated images of " + ta + " and " + tb);
	} else if (ancA[i] >= 0) {
		ta = formatTime(times[ancA[i]]);
		out("    not bracketed: phase propagated from " + ta + " with the mean synodic rate");
	}
	txt = formatTime(estLum[i]);
	out("  luminance curve alone gives: " + txt);
	if (!isNaN(estAlt[i])) {
		txt = formatTime(estAlt[i]);
		out("  lit side unclear (near full/new Moon); waning alternative: " + txt);
	}
}

// ---------------------------------------------------------------- plot
ymd = ymdOf(minArr(times, use));
axis0 = jdn(ymd[0], ymd[1], 1) - jdn(YEAR, 1, 1) - 1;    // x = 1.0 at 00:00 on the 1st of that month
monthNames = newArray("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December");
xs = newArray(0); ys = newArray(0);
for (i = 0; i < n; i++) if (use[i]) { xs = Array.concat(xs, times[i] - axis0); ys = Array.concat(ys, lum[i]); }
lo = minArr(times, use) - 2; hi = maxArr(times, use) + 2;
for (i = 0; i < n; i++) if (!use[i]) { lo = minOf(lo, estL[i] - 2); hi = maxOf(hi, estL[i] + 2); }
cx = newArray(400); cy = newArray(400);
for (q = 0; q < 400; q++) { tq = lo + (hi - lo) * q / 399; cx[q] = tq - axis0; cy[q] = FA + FB * lawAt(tq, FT0); }
ux = newArray(0); uy = newArray(0);
for (i = 0; i < n; i++) if (!use[i]) { ux = Array.concat(ux, estL[i] - axis0); uy = Array.concat(uy, lum[i]); }
ylabel = "Mean gray value";
if (correct) ylabel = "Mean gray value (size-corrected)";
Plot.create("Moon luminance vs time", "Day (1.0 = 1 " + monthNames[ymd[1] - 1] + " " + ymd[0] + ", 00:00)", ylabel);
Plot.setFrameSize(640, 360);
Plot.setLimits(lo - axis0, hi - axis0, 0, 1.12 * (FA + FB));
Plot.setColor("gray");
Plot.add("line", cx, cy);
Plot.setLineWidth(2);
Plot.setColor("blue");
Plot.add("circle", xs, ys);
Plot.setColor("red");
Plot.add("box", ux, uy);
Plot.setLegend("Fitted phase model\tDated images\tUnknown (estimated time)", "top-left");
Plot.show();

if (saveFiles) {
	File.makeDirectory(outDir);
	saveAs("PNG", outDir + "moon_luminance_plot.png");
	saveAs("Results", outDir + "moon_luminance.csv");
	File.saveString(SUMMARY, outDir + "moon_summary.txt");
	out("");
	out("Saved to " + outDir);
}
if (INTERACTIVE) setBatchMode("exit and display");
else setBatchMode(false);

// ================================================================ functions

function out(s) {
	print(s);
	SUMMARY = SUMMARY + s + "\n";
}

// Mean gray value of the whole frame, apparent radius and lit-side offset
function measureMoon() {
	if (bitDepth() != 8) run("8-bit");
	run("Select All");
	getStatistics(area, m);
	M_MEAN = m;
	run("Select None");
	w = getWidth(); h = getHeight();
	// the sunlit pixels lie on the side of the disk that faces the Sun
	litX = thresholdCentroidX(LIT_T);
	diskX = thresholdCentroidX(BG_T);
	side = 1;
	if (litX < diskX) side = -1;
	// limb points: outermost lit pixel of every row on the sunlit side, with sky just outside it
	// (on the other side the edge of the lit area is the terminator, even near full Moon)
	px = newArray(2 * h); py = newArray(2 * h); np = 0;
	for (y = 0; y < h; y++) {
		makeLine(0, y, w - 1, y);
		row = getProfile();
		if (side > 0) {
			for (x = w - 1; x >= 0; x--) if (row[x] >= LIT_T) break;
			if (x >= 0 && x < w - 6) {
				if (row[x + 3] < BG_T && row[x + 6] < BG_T) { px[np] = x; py[np] = y; np++; }
			}
		} else {
			for (x = 0; x < w; x++) if (row[x] >= LIT_T) break;
			if (x >= 6 && x < w) {
				if (row[x - 3] < BG_T && row[x - 6] < BG_T) { px[np] = x; py[np] = y; np++; }
			}
		}
	}
	run("Select None");
	if (np < 10) exit("Could not find the Moon limb in " + getTitle());
	fitCircle(px, py, np, w / 2, h / 2, 0);
	fitCircle(px, py, np, w / 2, h / 2, 3);
	fitCircle(px, py, np, w / 2, h / 2, 2);
	M_R = C_R;
	M_DX = (litX - (C_X + w / 2)) / C_R;
	// count the sunlit pixels
	getHistogram(values, counts, 256);
	nLit = 0;
	for (g = LIT_T; g < 256; g++) nLit += counts[g];
	M_K = nLit / (PI * C_R * C_R);
}

// Sun-Moon elongation 0..2*PI from the lit-area fraction k; d (lit-centroid shift) gives the side
function pixelPhase(k, d) {
	if (k < 0) k = 0;
	if (k > 1) k = 1;
	th = acos(1 - 2 * k);
	if (sideOf(d) < 0) th = 2 * PI - th;
	return th;
}

// Uncertainty (radians) of the elongation from pixelPhase(): an area error SIG_K*sin(theta)
// becomes 2*SIG_K in theta, the same at every phase
function phaseSigma(k, th) {
	return 2 * SIG_K;
}

// Time of an image with elongation phu (uncertainty su). The phases of the dated images are
// unwrapped along time, phu is unwrapped next to the phase expected at time ref, and the time is
// interpolated between the two consecutive dated images whose phases bracket it; if none do,
// the phase is propagated from the dated image nearest in time with the mean synodic rate.
function phaseTime(t, ph, sg, use, phu, su, ref) {
	m = 0;
	for (i = 0; i < t.length; i++) if (use[i]) m++;
	tt = newArray(m); ix = newArray(m); j = 0;
	for (i = 0; i < t.length; i++) if (use[i]) { tt[j] = t[i]; ix[j] = i; j++; }
	r = Array.rankPositions(tt);
	uw = newArray(m);
	for (q = 0; q < m; q++) {
		p = ph[ix[r[q]]];
		if (q > 0) p = p - 2 * PI * floor((p - uw[q - 1] + 0.5) / (2 * PI));    // not more than 0.5 rad behind
		uw[q] = p;
	}
	ex = uw[0] + 2 * PI * (ref - tt[r[0]]) / P;
	pu = phu + 2 * PI * round((ex - phu) / (2 * PI));
	for (q = 0; q < m - 1; q++) {
		if (uw[q] != uw[q + 1] && (pu - uw[q]) * (pu - uw[q + 1]) <= 0) {
			a = ix[r[q]]; b = ix[r[q + 1]];
			f = (pu - uw[q]) / (uw[q + 1] - uw[q]);
			rate = (uw[q + 1] - uw[q]) / (t[b] - t[a]);
			PT_A = a; PT_B = b;
			PT_SIG = sqrt(su * su + pow((1 - f) * sg[a], 2) + pow(f * sg[b], 2)) / abs(rate);
			return t[a] + f * (t[b] - t[a]);
		}
	}
	best = NaN; bd = 1e30;
	for (q = 0; q < m; q++) {
		a = ix[r[q]];
		e = t[a] + (pu - uw[q]) * P / (2 * PI);
		if (abs(e - t[a]) < bd) { bd = abs(e - t[a]); best = e; PT_A = a; }
	}
	PT_B = -1;
	PT_SIG = sqrt(su * su + sg[PT_A] * sg[PT_A]) * P / (2 * PI);
	return best;
}

// x centroid of the pixels with gray value >= lower
function thresholdCentroidX(lower) {
	setThreshold(lower, 255);
	run("Create Selection");
	List.setMeasurements;
	x = List.getValue("X");
	run("Select None");
	resetThreshold();
	return x;
}

// Least-squares (Kasa) circle fit; with tol > 0 only points within tol px of the previous circle are used
function fitCircle(px, py, np, ox, oy, tol) {
	sxx = 0; sxy = 0; syy = 0; sx = 0; sy = 0; sn = 0; sxz = 0; syz = 0; sz = 0;
	for (i = 0; i < np; i++) {
		x = px[i] - ox; y = py[i] - oy;
		if (tol > 0 && abs(sqrt((x - C_X) * (x - C_X) + (y - C_Y) * (y - C_Y)) - C_R) > tol) continue;
		z = x * x + y * y;
		sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; sn++;
		sxz += x * z; syz += y * z; sz += z;
	}
	d = det3(sxx, sxy, sx, sxy, syy, sy, sx, sy, sn);
	D = det3(-sxz, sxy, sx, -syz, syy, sy, -sz, sy, sn) / d;
	E = det3(sxx, -sxz, sx, sxy, -syz, sy, sx, -sz, sn) / d;
	F = det3(sxx, sxy, -sxz, sxy, syy, -syz, sx, sy, -sz) / d;
	C_X = -D / 2; C_Y = -E / 2;
	C_R = sqrt(C_X * C_X + C_Y * C_Y - F);
}

function det3(a, b, c, d, e, f, g, h, k) {
	return a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
}

// Phase law F for elongation th (0 = new Moon, PI = full Moon), 0..1
function law(th) {
	if (LAW == 1) return (1 - cos(th)) / 2;
	al = PI - th;    // phase angle Sun-Moon-Earth
	return (sin(al) + (PI - al) * cos(al)) / PI;
}

// F at time t for new-Moon time t0
function lawAt(t, t0) {
	ph = 2 * PI * (t - t0) / P;
	ph = ph - 2 * PI * floor(ph / (2 * PI));
	if (ph > PI) ph = 2 * PI - ph;
	return law(ph);
}

// Elongation 0..PI whose model luminance equals y (current fit); F increases with elongation
function elongation(y) {
	f = (y - FA) / FB;
	if (f <= 0) return 0;
	if (f >= 1) return PI;
	lo = 0; hi = PI;
	for (it = 0; it < 50; it++) {
		mid = (lo + hi) / 2;
		if (law(mid) < f) lo = mid;
		else hi = mid;
	}
	return (lo + hi) / 2;
}

// Fits L = a + b*F(t) to the images with use[i] = 1: grid search over t0, linear least squares for a and b
function fitModel(t, y, use) {
	tmin = minArr(t, use);
	best = 1e30; bt0 = tmin;
	step = 1 / 96;    // 15 min
	for (t0 = tmin - P; t0 < tmin; t0 += step) {
		s = sseFor(t, y, use, t0);
		if (s < best) { best = s; bt0 = t0; }
	}
	c = bt0;
	for (t0 = c - step; t0 <= c + step; t0 += 1 / 1440) {    // refine to 1 min
		s = sseFor(t, y, use, t0);
		if (s < best) { best = s; bt0 = t0; }
	}
	sseFor(t, y, use, bt0);
	FT0 = bt0;
	FN = 0;
	for (i = 0; i < t.length; i++) if (use[i]) FN++;
}

function sseFor(t, y, use, t0) {
	m = 0; sk = 0; sy = 0; skk = 0; sky = 0;
	for (i = 0; i < t.length; i++) {
		if (!use[i]) continue;
		k = lawAt(t[i], t0);
		m++; sk += k; sy += y[i]; skk += k * k; sky += k * y[i];
	}
	den = m * skk - sk * sk;
	if (den <= 0) return 1e30;
	b = (m * sky - sk * sy) / den;
	if (b <= 0) return 1e30;
	a = (sy - b * sk) / m;
	s = 0;
	for (i = 0; i < t.length; i++) {
		if (!use[i]) continue;
		r = y[i] - a - b * lawAt(t[i], t0);
		s += r * r;
	}
	FA = a; FB = b; FSSE = s;
	return s;
}

// Time from the global fit; side = 1 waxing, -1 waning. The cycle closest to the dated images is chosen.
function estimateGlobal(yu, side, t, use) {
	ph = elongation(yu);
	if (side < 0) ph = 2 * PI - ph;
	tt = FT0 + P * ph / (2 * PI);
	mid = (minArr(t, use) + maxArr(t, use)) / 2;
	return tt + P * round((mid - tt) / P);
}

// Time by linear interpolation of the (unwrapped) phase between the two dated
// images, consecutive in time, whose phases bracket the phase of the unknown
function estimateLocal(t, y, use, yu, side) {
	phu = 2 * PI * (estimateGlobal(yu, side, t, use) - FT0) / P;
	m = 0;
	for (i = 0; i < t.length; i++) if (use[i]) m++;
	tt = newArray(m); pp = newArray(m); j = 0;
	for (i = 0; i < t.length; i++) {
		if (!use[i]) continue;
		pm = 2 * PI * (t[i] - FT0) / P;            // model phase decides the branch of a dated image
		c = 2 * PI * floor(pm / (2 * PI));
		th = elongation(y[i]);
		if (pm - c < PI) pp[j] = c + th;
		else pp[j] = c + 2 * PI - th;
		tt[j] = t[i];
		j++;
	}
	r = Array.rankPositions(tt);
	for (q = 0; q < m - 1; q++) {
		p1 = pp[r[q]]; p2 = pp[r[q + 1]];
		if (p1 != p2 && (phu - p1) * (phu - p2) <= 0)
			return tt[r[q]] + (phu - p1) * (tt[r[q + 1]] - tt[r[q]]) / (p2 - p1);
	}
	return NaN;
}

function sideOf(d) {
	if (d > 0.01) return 1;
	if (d < -0.01) return -1;
	return 0;
}

function sideText(d) {
	s = sideOf(d);
	if (s > 0) return "right (waxing)";
	if (s < 0) return "left (waning)";
	return "unclear";
}

function minArr(a, use) {
	v = 1e30;
	for (i = 0; i < a.length; i++) if (use[i]) v = minOf(v, a[i]);
	return v;
}

function maxArr(a, use) {
	v = -1e30;
	for (i = 0; i < a.length; i++) if (use[i]) v = maxOf(v, a[i]);
	return v;
}

// ---------------------------------------------------------------- dates

function jdn(y, m, d) {    // Julian day number of a Gregorian date
	a = floor((14 - m) / 12);
	yy = y + 4800 - a;
	mm = m + 12 * a - 3;
	return d + floor((153 * mm + 2) / 5) + 365 * yy + floor(yy / 4) - floor(yy / 100) + floor(yy / 400) - 32045;
}

function ymdOf(t) {    // [year, month, day] of time t (days since 1 January YEAR)
	J = jdn(YEAR, 1, 1) + floor(round(t * 1440) / 1440);
	f = J + 1401 + floor(floor((4 * J + 274277) / 146097) * 3 / 4) - 38;
	e = 4 * f + 3;
	g = floor((e % 1461) / 4);
	h = 5 * g + 2;
	d = floor((h % 153) / 5) + 1;
	m = (floor(h / 153) + 2) % 12 + 1;
	y = floor(e / 1461) - 4716 + floor((14 - m) / 12);
	return newArray(y, m, d);
}

function formatTime(t) {
	months = newArray("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December");
	ymd = ymdOf(t);
	tm = round(t * 1440);
	mins = tm - 1440 * floor(tm / 1440);
	hh = floor(mins / 60);
	mi = mins - 60 * hh;
	h12 = hh % 12;
	if (h12 == 0) h12 = 12;
	ap = "AM";
	if (hh >= 12) ap = "PM";
	return "" + ymd[2] + " " + months[ymd[1] - 1] + " " + ymd[0] + ", " + IJ.pad(hh, 2) + ":" + IJ.pad(mi, 2) + " (" + IJ.pad(h12, 2) + ":" + IJ.pad(mi, 2) + " " + ap + ")";
}

function monthIndex(s) {    // 1..12 for a month name or its first 3+ letters, else 0
	months = newArray("january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december");
	if (lengthOf(s) < 3) return 0;
	for (m = 0; m < 12; m++) if (startsWith(months[m], s)) return m + 1;
	return 0;
}

// Reads e.g. "3_October_02_00AM.jpg", "31_October_12AM.jpg", "17_Oct_2026_13_30.png"
function parseFileTime(name) {
	s = toLowerCase(name);
	dot = lastIndexOf(s, ".");
	if (dot > 0) s = substring(s, 0, dot);
	s = replace(s, "[- .:]", "_");
	tok = split(s, "_");
	mi = -1; month = 0;
	for (i = 1; i < tok.length && mi < 0; i++) {
		month = monthIndex(tok[i]);
		if (month > 0) mi = i;
	}
	if (mi < 0) return NaN;
	day = parseInt(tok[mi - 1]);
	if (isNaN(day)) return NaN;
	year = YEAR;
	first = mi + 1;
	if (tok.length > first) {
		if (lengthOf(tok[first]) == 4 && !isNaN(parseInt(tok[first]))) { year = parseInt(tok[first]); first++; }
	}
	rest = "";
	for (i = first; i < tok.length; i++) rest = rest + tok[i] + "_";
	pm = indexOf(rest, "pm") >= 0;
	am = indexOf(rest, "am") >= 0;
	rest = replace(rest, "[ap]m", "");
	nums = split(rest, "_");
	hour = 0; minute = 0;
	if (nums.length > 0) hour = parseInt(nums[0]);
	if (nums.length > 1) minute = parseInt(nums[1]);
	if (isNaN(hour) || isNaN(minute)) return NaN;
	if (am && hour == 12) hour = 0;
	if (pm && hour < 12) hour += 12;
	return jdn(year, month, day) - jdn(YEAR, 1, 1) + hour / 24 + minute / 1440;
}

// Asks for the date of an image whose file name has none. Empty answer = undated; -1e30 = skip.
function askTime(name) {
	if (!INTERACTIVE) {
		print("Skipped " + name + ": no date in the file name.");
		return -1e30;
	}
	Dialog.create("Date of " + name);
	Dialog.addMessage("No date could be read from the file name.\nEnter it as dd.mm.yyyy hh:mm, or leave it empty if this image is undated.");
	Dialog.addString("Date and time:", "", 20);
	Dialog.show();
	s = Dialog.getString();
	if (s == "") return NaN;
	v = split(s, ". :/");
	if (v.length < 3) return -1e30;
	hh = 0; mm = 0;
	if (v.length > 3) hh = parseInt(v[3]);
	if (v.length > 4) mm = parseInt(v[4]);
	return jdn(parseInt(v[2]), parseInt(v[1]), parseInt(v[0])) - jdn(YEAR, 1, 1) + hh / 24 + mm / 1440;
}
