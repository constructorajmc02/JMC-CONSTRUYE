// ===== Menú móvil =====
const toggle = document.getElementById("navToggle");
const nav = document.getElementById("nav");
if (toggle && nav) {
  toggle.addEventListener("click", () => {
    const open = nav.classList.toggle("open");
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
  });
}

// ===== Año en el footer =====
const yearEl = document.getElementById("year");
if (yearEl) yearEl.textContent = new Date().getFullYear();

// ===== Carrusel deslizante: duplica los ítems para un bucle continuo =====
document.querySelectorAll(".marquee-track").forEach((track) => {
  Array.from(track.children).forEach((node) => {
    const clone = node.cloneNode(true);
    clone.setAttribute("aria-hidden", "true");
    track.appendChild(clone);
  });
});

// ===== Aparición suave al hacer scroll =====
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
if (!reduceMotion && "IntersectionObserver" in window) {
  // [selector, escalonado en ms entre ítems del mismo grupo]
  const groups = [
    [".hero-inner > div", 90],
    [".values .value", 90],
    [".page-hero .container", 0],
    [".section-head", 0],
    [".about-grid > div", 120],
    [".purpose-card", 0],
    [".service-card", 80],
    [".project-cat", 120],
    [".marquee", 0],
    [".cta-band .container", 0],
    [".contact-block", 100],
    [".contact-form", 0],
  ];

  const targets = [];
  groups.forEach(([selector, step]) => {
    document.querySelectorAll(selector).forEach((el, i) => {
      if (el.closest(".marquee-track")) return; // no ocultar ítems del carrusel
      el.setAttribute("data-reveal", "");
      if (step) el.style.transitionDelay = Math.min(i * step, 480) + "ms";
      targets.push(el);
    });
  });

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          io.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -6% 0px" }
  );

  targets.forEach((el) => io.observe(el));
}
