// Search stays entirely in the browser. No device access or configuration writes.
export function normalizeSearch(value) {
  return String(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

export function matchesAction(text, query, actionCategory, selectedCategory = "all") {
  if (selectedCategory !== "all" && selectedCategory !== actionCategory) return false;
  const searchable = normalizeSearch(text);
  return normalizeSearch(query).split(/\s+/).filter(Boolean).every((word) => searchable.includes(word));
}
