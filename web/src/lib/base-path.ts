import { normalizeBasePath } from "../../base-path";

declare global {
  interface ImportMetaEnv {
    BASE_URL: string;
  }

  interface ImportMeta {
    readonly env: ImportMetaEnv;
  }
}

// Vite sets BASE_URL from vite.config.ts's validated COLLIE_BASE_PATH value.
export const COLLIE_BASE_PATH = normalizeBasePath(import.meta.env.BASE_URL);

/** Prefix an origin-relative application URL with the configured public mount. */
export function withBasePath(path: string): string {
  if (!path.startsWith("/")) throw new Error(`Expected an origin-relative path, got ${path}`);
  return `${COLLIE_BASE_PATH === "/" ? "" : COLLIE_BASE_PATH.slice(0, -1)}${path}`;
}
