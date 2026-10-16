"use strict";
(function () {
	const SPRAY_GAP = 0.1;
	const STEP_INTERVAL = 0.15;
	const MAX_STEP = 4;
	const ABILITY_DURATION = 0.1;
	const ABILITY_MIN_INTERVAL = 0.1;
	const BULLET_WINDOW = 0.1;
	const BULLET_SETTLE = 0.05;
	const ABILITY_SOUND = "ImprovedHitmarker.Ability";
	const IMPACT_BARS = ["healthRemaining", "healthRemoved", "techShieldRemaining", "techShieldRemoved", "bulletShieldRemaining", "bulletShieldRemoved"];
	const IMPACT_CLASSES = ["fadeIn", "fadeOut", "Critical", "killed", "assist", "is_heal"];
	const DEBUG = false;
	const root = $.GetContextPanel();
	let hitShown = false;
	let critShown = false;
	let abilityShown = false;
	let abilityUntil = 0;
	let lastAbility = -Infinity;
	let lastBullet = -Infinity;
	let sprayStart = 0;
	let lastActive = -Infinity;
	let step = 0;
	let impactInfo = null;
	let impacts = [];

	function log(message) {
		if (DEBUG) {
			$.Msg("[improved_hitmarker] " + (Date.now() / 1000).toFixed(3) + " " + message);
		}
	}

	function hasClassInChain(panel, name) {
		for (let current = panel; current; current = current.GetParent()) {
			if (current.BHasClass(name)) {
				return true;
			}
		}
		return false;
	}

	function setStep(value) {
		if (value === step) {
			return;
		}
		step = value;
		for (let index = 1; index <= MAX_STEP; index++) {
			root.SetHasClass("hf_step_" + index, index === value);
		}
	}

	function findImpactInfo() {
		if (impactInfo && impactInfo.IsValid()) {
			return impactInfo;
		}
		let hud = root;
		while (hud.GetParent()) {
			hud = hud.GetParent();
		}
		impactInfo = hud.FindChildTraverse("damageImpactInfo");
		log("damageImpactInfo " + (impactInfo ? "found" : "missing"));
		return impactInfo;
	}

	function readImpact(panel) {
		const state = { bars: {}, classes: {} };
		for (const name of IMPACT_BARS) {
			const bar = panel.FindChildTraverse(name);
			state.bars[name] = bar ? { style: String(bar.style.width), layout: Math.round(bar.actuallayoutwidth) } : null;
		}
		for (const name of IMPACT_CLASSES) {
			state.classes[name] = panel.BHasClass(name);
		}
		return state;
	}

	function describe(state) {
		const bars = IMPACT_BARS.map(function (name) {
			const bar = state.bars[name];
			return name + "=" + (bar ? bar.style + "/" + bar.layout : "-");
		});
		const classes = IMPACT_CLASSES.filter(function (name) { return state.classes[name]; });
		return bars.join(" ") + " [" + classes.join(",") + "]";
	}

	function isDamage(previous, current) {
		if (current.classes.is_heal) {
			return false;
		}
		if (!previous) {
			return true;
		}
		if (current.classes.killed && !previous.classes.killed) {
			return true;
		}
		if (current.classes.killed || current.classes.assist) {
			return false;
		}
		for (const name of IMPACT_BARS) {
			const before = previous.bars[name];
			const after = current.bars[name];
			if (!before || !after) {
				continue;
			}
			const delta = parseFloat(after.style) - parseFloat(before.style);
			if (name.endsWith("Remaining") ? delta < 0 : delta > 0) {
				return true;
			}
		}
		return false;
	}

	function pollImpacts(now) {
		const info = findImpactInfo();
		if (!info) {
			return false;
		}
		let damaged = false;
		const next = [];
		for (let index = 0; index < info.GetChildCount(); index++) {
			const panel = info.GetChild(index);
			const current = readImpact(panel);
			const known = impacts.find(function (entry) { return entry.panel === panel; });
			const previous = known ? known.state : null;
			const text = describe(current);
			if (!previous || text !== describe(previous)) {
				log("impact " + index + (previous ? "" : " new") + " " + text);
			}
			if (isDamage(previous, current)) {
				damaged = true;
			}
			next.push({ panel: panel, state: current });
		}
		impacts = next;
		return damaged;
	}

	function playAbilitySound() {
		try {
			$.DispatchEvent("PlaySoundEffect", ABILITY_SOUND);
		} catch (error) {
			log("sound failed " + error);
		}
	}

	function confirmAbility(detected) {
		const now = Date.now() / 1000;
		if (Math.abs(lastBullet - detected) <= BULLET_WINDOW) {
			log("impact matched a bullet hit");
			return;
		}
		if (now - lastAbility < ABILITY_MIN_INTERVAL) {
			return;
		}
		lastAbility = now;
		abilityUntil = now + ABILITY_DURATION;
		log("ability hit");
		playAbilitySound();
	}

	function tick() {
		if (!root.IsValid()) {
			return;
		}
		const now = Date.now() / 1000;
		const hit = hasClassInChain(root, "show_hit_marker");
		const crit = hasClassInChain(root, "show_crit_hit_marker");

		if ((hit && !hitShown) || (crit && !critShown)) {
			lastBullet = now;
		}

		if (pollImpacts(now)) {
			$.Schedule(BULLET_SETTLE, function () { confirmAbility(now); });
		}

		const ability = now < abilityUntil;
		root.SetHasClass("hf_ability", ability);

		if (crit && !critShown) {
			root.SetHasClass("hf_crit", true);
		} else if ((hit && !hitShown) || (ability && !abilityShown)) {
			root.SetHasClass("hf_crit", false);
		}

		if (hit || crit || ability) {
			if (now - lastActive > SPRAY_GAP) {
				sprayStart = now;
			}
			lastActive = now;
			setStep(Math.min(MAX_STEP, 1 + Math.floor((now - sprayStart) / STEP_INTERVAL)));
		}

		hitShown = hit;
		critShown = crit;
		abilityShown = ability;
		$.Schedule(0.0, tick);
	}

	setStep(1);
	root.AddClass("hf_ready");
	log("loaded");
	tick();
})();
