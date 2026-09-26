/* Springs parameterised the way Apple does it: a damping ratio and a response
   time, instead of mass / stiffness / damping.

     damping  1.0  critically damped - settles without any overshoot
     response      seconds to get (almost) there; not a fixed duration

   Every motion starts from the value currently on screen and keeps its
   velocity when handed a new target. That is what makes it interruptible:
   retarget it mid-flight and it simply turns around, no jump, no wait. */

class Spring {
  constructor(value = 0, { damping = 1, response = 0.4, precision = 0.001 } = {}) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
    this.precision = precision;
    this.configure(damping, response);
  }

  configure(damping, response) {
    const omega = (2 * Math.PI) / response;   // natural frequency, unit mass
    this.stiffness = omega * omega;           // (2π / response)²
    this.friction = 2 * damping * omega;      // 4π·ζ / response
    return this;
  }

  /* New target, starting from wherever the value is now. */
  to(target) {
    this.target = target;
    return this;
  }

  /* Move without animating - FLIP uses it to hold an element in place. */
  set(value) {
    this.value = value;
    return this;
  }

  get settled() {
    return Math.abs(this.target - this.value) < this.precision &&
           Math.abs(this.velocity) < this.precision * 10;
  }

  step(dt) {
    // Fixed sub-steps: identical motion at 60 Hz and at 120 Hz.
    const h = 1 / 240;
    for (let left = dt; left > 1e-6; left -= h) {
      const s = Math.min(h, left);
      const force = -this.stiffness * (this.value - this.target) - this.friction * this.velocity;
      this.velocity += force * s;
      this.value += this.velocity * s;
    }
    if (this.settled) {
      this.value = this.target;
      this.velocity = 0;
    }
  }
}

/* One display-synced clock for everything that moves. A task returns true
   while it still has work; the loop parks itself when nothing moves. */
const Animator = (() => {
  const tasks = new Set();
  let raf = 0;
  let last = 0;

  function frame(now) {
    // Clamped both ways: rAF can report a time slightly before the moment a
    // task was added, and after a stall (hidden tab, GC) motion must catch up
    // smoothly rather than teleport.
    const dt = Math.min(Math.max((now - last) / 1000, 0), 1 / 30);
    last = now;
    for (const task of [...tasks]) {
      if (!task(dt)) tasks.delete(task);
    }
    raf = tasks.size ? requestAnimationFrame(frame) : 0;
  }

  return {
    run(task) {
      tasks.add(task);
      if (!raf) {
        last = performance.now();
        raf = requestAnimationFrame(frame);
      }
    },
  };
})();
