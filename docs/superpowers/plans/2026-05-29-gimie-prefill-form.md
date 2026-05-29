# Gimie Prefill of publiccode-editor Form — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Prefill from GitHub" button + modal to the publiccode-editor that sends a repo URL to gimie-api and populates the form with the extracted metadata.

**Architecture:** gimie-api gains a `/publiccode/{repo}` endpoint that runs gimie and maps the RDF graph to a publiccode object via the PR #138 converter. The editor gets a thin importer, a modal that owns the fetch + loading/error UX, and a toolbar button. On success the modal hands the fetched object to `Editor.tsx` through the existing `mitt` event bus, which reuses the established `processImported` pipeline to reset-then-fill the react-hook-form.

**Tech Stack:** FastAPI + gimie (Python) on the API side; React 18 + react-hook-form + design-react-kit + mitt + Jest (TypeScript) on the editor side.

---

## Context for the implementer

- The gimie submodule (`modules/gimie`) is on branch `pr-138`, which provides `gimie/converters/publiccode.py` with `convert_to_publiccode(graph) -> dict`. Verified importable in the running container as `gimie.converters.publiccode`.
- gimie-api runs in Docker (`gimie-api-dev` container) on host port **45400** (container 15400). Source is live-mounted: `modules/gimie-api/app` → `/app`, served as `app.main:app` with `WORKDIR /` and `--reload`.
- CORS on gimie-api already allows `http://localhost:3000` (the editor's Vite dev port) — no CORS change needed.
- Editor import pipeline (existing, do not rebuild): an importer returns a `PublicCode`-shaped object → `processImported(raw)` runs `publicCodeAdapter` + `linter` → `setFormDataAfterImport` → `reset(form)`. See `Editor.tsx:418` (`processImported`) and `Editor.tsx:459` (`loadRemoteYamlHandler`).
- The event bus `yamlLoadEventBus` (a `mitt` instance) and its `YamlLoadEvents` type are defined at the top of `src/app/components/UploadPanel.tsx`. `Editor.tsx` subscribes in a `useEffect` (`Editor.tsx:480`).

## File structure

- `modules/gimie-api/app/main.py` — modify: add `/publiccode/{full_path:path}` endpoint.
- `modules/gimie-api/app/tests/test_publiccode_endpoint.py` — create: endpoint test (monkeypatched `Project`).
- `modules/publiccode-editor/src/app/contents/constants.ts` — modify: add `VITE_GIMIE_API_URL`.
- `modules/publiccode-editor/src/app/importers/gimie.importer.ts` — create: `importFromGimie` + `normalizeGimiePublicCode`.
- `modules/publiccode-editor/src/app/importers/gimie.importer.spec.ts` — create: importer tests.
- `modules/publiccode-editor/src/app/components/UploadPanel.tsx` — modify: extend `YamlLoadEvents` with `prefillFromGimie`.
- `modules/publiccode-editor/src/app/components/Editor.tsx` — modify: add `prefillFromGimieHandler` + subscribe.
- `modules/publiccode-editor/src/app/components/GimiePrefillModal.tsx` — create: the modal (URL input, loading, error).
- `modules/publiccode-editor/src/app/components/YamlPreview.tsx` — modify: add the button + render the modal.

**Note on commits:** Each task commits within the relevant git repo. `modules/gimie-api` and `modules/publiccode-editor` are independent submodules with their own history; run `git` from inside the submodule directory. Do NOT commit submodule pointer bumps in the superproject as part of these tasks.

---

### Task 1: gimie-api `/publiccode/{repo}` endpoint

**Files:**
- Modify: `modules/gimie-api/app/main.py`
- Test: `modules/gimie-api/app/tests/test_publiccode_endpoint.py`

- [ ] **Step 1: Write the failing test**

Create `modules/gimie-api/app/tests/test_publiccode_endpoint.py`:

```python
from fastapi.testclient import TestClient
from rdflib import Graph, Literal, URIRef
from rdflib.namespace import RDF

import app.main as main
from gimie.graph.namespaces import SDO


def _fake_graph() -> Graph:
    g = Graph()
    s = URIRef("https://github.com/org/repo")
    g.add((s, RDF.type, SDO.SoftwareSourceCode))
    g.add((s, SDO.name, Literal("org/repo")))
    g.add((s, SDO.description, Literal("A test repository")))
    g.add((s, SDO.license, URIRef("https://spdx.org/licenses/MIT.html")))
    return g


def test_publiccode_endpoint_returns_mapped_object(monkeypatch):
    class FakeProject:
        def __init__(self, url):
            self.url = url

        def extract(self):
            return _fake_graph()

    monkeypatch.setattr(main, "Project", FakeProject)

    client = TestClient(main.app)
    res = client.get("/publiccode/https://github.com/org/repo")

    assert res.status_code == 200
    data = res.json()
    assert data["name"] == "repo"
    assert data["url"] == "https://github.com/org/repo"
    assert data["legal"]["license"] == "MIT"
    assert data["description"]["en"]["shortDescription"] == "A test repository"


def test_publiccode_endpoint_returns_502_on_failure(monkeypatch):
    class BoomProject:
        def __init__(self, url):
            pass

        def extract(self):
            raise RuntimeError("extraction failed")

    monkeypatch.setattr(main, "Project", BoomProject)

    client = TestClient(main.app)
    res = client.get("/publiccode/https://github.com/org/repo")

    assert res.status_code == 502
    assert "error" in res.json()
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
docker exec gimie-api-dev sh -c "cd / && pip install -q pytest httpx && python -m pytest app/tests/test_publiccode_endpoint.py -v -o addopts=''"
```
Expected: FAIL — `404 != 200` (endpoint does not exist yet).

- [ ] **Step 3: Add the endpoint**

In `modules/gimie-api/app/main.py`, add this import near the top (after `from gimie.project import Project`):

```python
from gimie.converters.publiccode import convert_to_publiccode
```

Then add this route (place it after the existing `/gimie/jsonld` handler):

```python
@app.get("/publiccode/{full_path:path}")
async def gimie_publiccode(full_path: str):
    """Run gimie on a repo URL and return a publiccode-shaped object."""
    try:
        proj = Project(full_path)
        graph = proj.extract()
        return convert_to_publiccode(graph)
    except Exception as e:
        return JSONResponse(
            status_code=502,
            content={"link": full_path, "error": str(e)},
        )
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
docker exec gimie-api-dev sh -c "cd / && python -m pytest app/tests/test_publiccode_endpoint.py -v -o addopts=''"
```
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
cd modules/gimie-api
git add app/main.py app/tests/test_publiccode_endpoint.py
git commit -m "feat: add /publiccode endpoint mapping gimie output to publiccode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Editor config — `VITE_GIMIE_API_URL`

**Files:**
- Modify: `modules/publiccode-editor/src/app/contents/constants.ts`

- [ ] **Step 1: Add the env var**

In `modules/publiccode-editor/src/app/contents/constants.ts`, extend the destructured `import.meta.env` block and add an exported default. Result:

```ts
export const {
  VITE_REPOSITORY: REPOSITORY,
  VITE_ELASTIC_URL: ELASTIC_URL,
  VITE_VALIDATOR_URL: VALIDATOR_URL,
  VITE_VALIDATOR_REMOTE_URL: VALIDATOR_REMOTE_URL,
  VITE_DEFAULT_COUNTRY: DEFAULT_COUNTRY,
  VITE_FALLBACK_LANGUAGE: FALLBACK_LANGUAGE = "en",
  VITE_DEFAULT_COUNTRY_SECTIONS: DEFAULT_COUNTRY_SECTIONS = "none",
  VITE_GIMIE_API_URL: GIMIE_API_URL_ENV,
} = import.meta.env;

export const GIMIE_API_URL = GIMIE_API_URL_ENV || "http://localhost:45400";
```

(Leave the rest of the file unchanged.)

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd modules/publiccode-editor && npx tsc --noEmit -p tsconfig.json
```
Expected: no new errors referencing `constants.ts`.

- [ ] **Step 3: Commit**

```bash
cd modules/publiccode-editor
git add src/app/contents/constants.ts
git commit -m "feat: add GIMIE_API_URL config constant

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Editor importer — `gimie.importer.ts`

**Files:**
- Create: `modules/publiccode-editor/src/app/importers/gimie.importer.ts`
- Test: `modules/publiccode-editor/src/app/importers/gimie.importer.spec.ts`

- [ ] **Step 1: Write the failing test**

Create `modules/publiccode-editor/src/app/importers/gimie.importer.spec.ts`:

```ts
jest.mock("../contents/constants", () => ({
  GIMIE_API_URL: "http://gimie.test",
}));

import importFromGimie, { normalizeGimiePublicCode } from "./gimie.importer";

describe("normalizeGimiePublicCode", () => {
  it("normalizes publiccodeYmlVersion 0.5 to 0.5.0", () => {
    const out = normalizeGimiePublicCode({
      publiccodeYmlVersion: "0.5",
    } as never);
    expect(out.publiccodeYmlVersion).toBe("0.5.0");
  });

  it("strips emails from maintenance contacts", () => {
    const out = normalizeGimiePublicCode({
      maintenance: {
        type: "internal",
        contacts: [{ name: "Jane", email: "corrupted" }],
      },
    } as never);
    expect(out.maintenance.contacts[0]).toEqual({ name: "Jane" });
  });

  it("leaves a null contacts list untouched", () => {
    const out = normalizeGimiePublicCode({
      maintenance: { type: "community", contacts: null },
    } as never);
    expect(out.maintenance.contacts).toBeNull();
  });
});

describe("importFromGimie", () => {
  afterEach(() => jest.restoreAllMocks());

  it("calls the gimie endpoint with the repo URL and returns normalized data", async () => {
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ publiccodeYmlVersion: "0.5", name: "repo" }),
    });
    global.fetch = fetchMock as never;

    const pc = await importFromGimie(new URL("https://github.com/org/repo"));

    expect(fetchMock).toHaveBeenCalledWith(
      "http://gimie.test/publiccode/https://github.com/org/repo",
    );
    expect(pc.name).toBe("repo");
    expect(pc.publiccodeYmlVersion).toBe("0.5.0");
  });

  it("throws when the response is not ok", async () => {
    global.fetch = jest
      .fn()
      .mockResolvedValue({ ok: false, status: 502 }) as never;

    await expect(
      importFromGimie(new URL("https://github.com/org/repo")),
    ).rejects.toThrow("502");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd modules/publiccode-editor && npx jest src/app/importers/gimie.importer.spec.ts
```
Expected: FAIL — cannot find module `./gimie.importer`.

- [ ] **Step 3: Write the importer**

Create `modules/publiccode-editor/src/app/importers/gimie.importer.ts`:

```ts
import { GIMIE_API_URL } from "../contents/constants";
import type PublicCode from "../contents/publiccode";

/**
 * Normalize quirks of the gimie PR #138 converter output:
 * - publiccodeYmlVersion comes back as "0.5"; the editor expects "0.5.0".
 * - contact emails are corrupted by the converter (@ replaced with 'd'),
 *   so drop them until the upstream PR is fixed.
 */
export const normalizeGimiePublicCode = (pc: PublicCode): PublicCode => {
  const normalized: PublicCode = { ...pc };

  if (normalized.publiccodeYmlVersion === "0.5") {
    normalized.publiccodeYmlVersion = "0.5.0";
  }

  const contacts = normalized.maintenance?.contacts;
  if (Array.isArray(contacts)) {
    normalized.maintenance = {
      ...normalized.maintenance,
      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      contacts: contacts.map(({ email, ...rest }) => rest),
    };
  }

  return normalized;
};

const importFromGimie = async (repoUrl: URL): Promise<PublicCode> => {
  const res = await fetch(`${GIMIE_API_URL}/publiccode/${repoUrl.href}`);
  if (!res.ok) {
    throw new Error(`gimie-api responded ${res.status}`);
  }
  const pc = (await res.json()) as PublicCode;
  return normalizeGimiePublicCode(pc);
};

export default importFromGimie;
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd modules/publiccode-editor && npx jest src/app/importers/gimie.importer.spec.ts
```
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
cd modules/publiccode-editor
git add src/app/importers/gimie.importer.ts src/app/importers/gimie.importer.spec.ts
git commit -m "feat: add gimie importer with output normalization

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Editor — event bus event + handler

**Files:**
- Modify: `modules/publiccode-editor/src/app/components/UploadPanel.tsx` (type only)
- Modify: `modules/publiccode-editor/src/app/components/Editor.tsx`

- [ ] **Step 1: Extend the event bus type**

In `modules/publiccode-editor/src/app/components/UploadPanel.tsx`, find the `YamlLoadEvents` type (near the top) and add the `prefillFromGimie` event. Result:

```ts
type YamlLoadEvents = {
  loadRemoteYaml: { url: string; source: "gitlab" | "other" };
  loadFileYaml: File;
  prefillFromGimie: PublicCode;
};
```

Add this import at the top of `UploadPanel.tsx` if `PublicCode` is not already imported:

```ts
import type PublicCode from "../contents/publiccode";
```

- [ ] **Step 2: Add the handler in Editor.tsx**

In `modules/publiccode-editor/src/app/components/Editor.tsx`, immediately after `loadRemoteYamlHandler` (ends around line 477), add:

```tsx
  const prefillFromGimieHandler = async (raw: PublicCode) => {
    resetFormHandler();
    await processImported(raw);
  };
```

- [ ] **Step 3: Subscribe to the event**

In the same file, in the `useEffect` that registers bus listeners (around line 480), add registration and cleanup for the new event. Result:

```tsx
  useEffect(() => {
    yamlLoadEventBus.on("loadRemoteYaml", loadRemoteYamlHandler);
    yamlLoadEventBus.on("loadFileYaml", loadFileYamlHandler);
    yamlLoadEventBus.on("prefillFromGimie", prefillFromGimieHandler);

    return () => {
      yamlLoadEventBus.off("loadRemoteYaml", loadRemoteYamlHandler);
      yamlLoadEventBus.off("loadFileYaml", loadFileYamlHandler);
      yamlLoadEventBus.off("prefillFromGimie", prefillFromGimieHandler);
    };
  }, []);
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd modules/publiccode-editor && npx tsc --noEmit -p tsconfig.json
```
Expected: no new errors in `Editor.tsx` or `UploadPanel.tsx`.

- [ ] **Step 5: Commit**

```bash
cd modules/publiccode-editor
git add src/app/components/UploadPanel.tsx src/app/components/Editor.tsx
git commit -m "feat: wire prefillFromGimie event into editor import pipeline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Editor — `GimiePrefillModal` component

**Files:**
- Create: `modules/publiccode-editor/src/app/components/GimiePrefillModal.tsx`

This modal owns the fetch and the loading/error UX (gimie takes several seconds). On success it emits `prefillFromGimie` with the fetched object and closes; the Editor handler from Task 4 does the form reset + fill.

- [ ] **Step 1: Create the component**

Create `modules/publiccode-editor/src/app/components/GimiePrefillModal.tsx`:

```tsx
import {
  Button,
  Icon,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
} from "design-react-kit";
import { FormEvent, useState } from "react";
import { useTranslation } from "react-i18next";
import importFromGimie from "../importers/gimie.importer";
import { yamlLoadEventBus } from "./UploadPanel";

interface Props {
  isOpen: boolean;
  toggle: () => void;
}

export default function GimiePrefillModal({ isOpen, toggle }: Props) {
  const { t } = useTranslation();
  const [url, setUrl] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);

    let repoUrl: URL;
    try {
      repoUrl = new URL(url);
    } catch {
      setError(t("editor.notvalidurl"));
      return;
    }

    setLoading(true);
    try {
      const publicCode = await importFromGimie(repoUrl);
      yamlLoadEventBus.emit("prefillFromGimie", publicCode);
      setUrl("");
      toggle();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Modal isOpen={isOpen} toggle={toggle} scrollable>
      <ModalHeader toggle={toggle}>Prefill from a GitHub repo</ModalHeader>
      <ModalBody>
        <form id="gimie-prefill" onSubmit={handleSubmit}>
          <p>Paste a GitHub repository URL; gimie will extract metadata.</p>
          <input
            className="form-control"
            placeholder="https://github.com/org/repo"
            type="url"
            value={url}
            disabled={loading}
            onChange={(e) => setUrl(e.target.value)}
          />
          {error && <p className="text-danger mt-2">{error}</p>}
        </form>
      </ModalBody>
      <ModalFooter>
        <Button
          color="primary"
          type="submit"
          form="gimie-prefill"
          disabled={loading || !url}
        >
          {loading ? (
            <Icon color="white" icon="it-refresh" size="sm" />
          ) : (
            <Icon color="white" icon="it-download" size="sm" />
          )}
          <span className="ms-1">
            {loading ? "Extracting…" : "Prefill"}
          </span>
        </Button>
      </ModalFooter>
    </Modal>
  );
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd modules/publiccode-editor && npx tsc --noEmit -p tsconfig.json
```
Expected: no new errors in `GimiePrefillModal.tsx`.

- [ ] **Step 3: Commit**

```bash
cd modules/publiccode-editor
git add src/app/components/GimiePrefillModal.tsx
git commit -m "feat: add GimiePrefillModal with loading and error states

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Editor — button in YamlPreview footer

**Files:**
- Modify: `modules/publiccode-editor/src/app/components/YamlPreview.tsx`

- [ ] **Step 1: Import the modal and add open state**

In `modules/publiccode-editor/src/app/components/YamlPreview.tsx`, add the import near the other component imports:

```tsx
import GimiePrefillModal from "./GimiePrefillModal";
```

Inside the component body, next to the existing `const [showUploadPanel, setShowUploadPanel] = useState(false);` (line 39), add:

```tsx
  const [showGimieModal, setShowGimieModal] = useState(false);
```

- [ ] **Step 2: Add the button and render the modal**

In the `preview__footer` block, add a new button after the existing "Load" button `</div>` (the block ending at line 97). Insert:

```tsx
        <div>
          <Button
            className="d-flex gap-1 justify-content-center align-items-center"
            onClick={(e) => {
              e.preventDefault();
              setShowGimieModal(true);
            }}
          >
            <Icon color="white" icon="it-github" size="sm" />
            <span className="action">Prefill from GitHub</span>
          </Button>
        </div>
        <GimiePrefillModal
          isOpen={showGimieModal}
          toggle={() => setShowGimieModal((v) => !v)}
        />
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
cd modules/publiccode-editor && npx tsc --noEmit -p tsconfig.json
```
Expected: no new errors in `YamlPreview.tsx`.

- [ ] **Step 4: Commit**

```bash
cd modules/publiccode-editor
git add src/app/components/YamlPreview.tsx
git commit -m "feat: add Prefill from GitHub button to YAML preview footer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: End-to-end manual verification

**Files:** none (verification only).

This feature's UI wiring is not unit-tested (the codebase has no React component test setup); verify it manually.

- [ ] **Step 1: Confirm gimie-api is up and the endpoint works**

Run:
```bash
curl -s --max-time 90 "http://localhost:45400/publiccode/https://github.com/sdsc-ordes/gimie" | python3 -m json.tool
```
Expected: a JSON object with `name`, `url`, `description`, `legal.license`, `maintenance`.

- [ ] **Step 2: Run the editor dev server**

Run:
```bash
cd modules/publiccode-editor && pnpm install && pnpm dev
```
Expected: Vite serves on `http://localhost:3000`.

- [ ] **Step 3: Exercise the flow in the browser**

1. Open `http://localhost:3000`.
2. In the YAML preview footer, click **"Prefill from GitHub"**.
3. Paste `https://github.com/sdsc-ordes/gimie` and click **Prefill**.
4. Confirm: the button shows "Extracting…", the modal closes on success, and the form fields (name, url, description, license, maintenance contacts) are populated.
5. Confirm an invalid URL (e.g. `not-a-url`) shows the inline error and does not submit.

- [ ] **Step 4: Run the full editor test suite to confirm no regressions**

Run:
```bash
cd modules/publiccode-editor && npx jest
```
Expected: all tests pass (including the new `gimie.importer.spec.ts`).

---

## Notes / known limitations (carried from the spec)

- Only ~8 fields are derivable; `platforms`, `developmentStatus`, `softwareType`, etc. stay empty by design.
- gimie extraction takes a few seconds and needs a `GITHUB_TOKEN` (already in the gimie-api `.env`); public repos only.
- Contact emails are dropped in `normalizeGimiePublicCode` because PR #138 corrupts them; revisit once the PR is fixed.
- Depends on the `pr-138` branch in `modules/gimie` providing `convert_to_publiccode`.
