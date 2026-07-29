/**
 * Normalize the public mount path shared by Vite and the browser bundle.
 *
 * Only absolute pathnames are accepted: a proxy mount must never be interpreted
 * as an origin, query, or fragment. A trailing slash keeps URL joins unambiguous.
 */
export function normalizeBasePath(raw: string | undefined): string {
  const value = raw?.trim();
  if (!value) return "/";
  if (!value.startsWith("/")) {
    throw new Error("COLLIE_BASE_PATH must be an absolute pathname starting with '/'");
  }

  const path = value.endsWith("/") ? value : `${value}/`;
  const url = new URL(path, "https://collie.invalid");
  if (
    url.origin !== "https://collie.invalid" ||
    url.pathname !== path ||
    url.search ||
    url.hash ||
    path.includes("//")
  ) {
    throw new Error("COLLIE_BASE_PATH must be a normalized absolute pathname");
  }

  return path;
}
