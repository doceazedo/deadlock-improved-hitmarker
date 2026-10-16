"use strict";
(function () {
	const SPRAY_GAP = 0.1;
	const STEP_INTERVAL = 0.15;
	const MAX_STEP = 4;
	const root = $.GetContextPanel();
	let hitShown = false;
	let critShown = false;
	let sprayStart = 0;
	let lastActive = -Infinity;
	let step = 0;

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

	function tick() {
		if (!root.IsValid()) {
			return;
		}
		const now = Date.now() / 1000;
		const hit = hasClassInChain(root, "show_hit_marker");
		const crit = hasClassInChain(root, "show_crit_hit_marker");

		if (crit && !critShown) {
			root.SetHasClass("hf_crit", true);
		} else if (hit && !hitShown) {
			root.SetHasClass("hf_crit", false);
		}

		if (hit || crit) {
			if (now - lastActive > SPRAY_GAP) {
				sprayStart = now;
			}
			lastActive = now;
			setStep(Math.min(MAX_STEP, 1 + Math.floor((now - sprayStart) / STEP_INTERVAL)));
		}

		hitShown = hit;
		critShown = crit;
		$.Schedule(0.0, tick);
	}

	setStep(1);
	root.AddClass("hf_ready");
	tick();
})();
