# Prefill publiccode-editor form from a GitHub repo via gimie

**Date:** 2026-05-29
**Status:** Approved (design)

## Summary

Add a "Prefill from GitHub" button to the publiccode-editor. It opens a modal where
the user pastes a GitHub repository URL. The URL is sent to `gimie-api`, which runs
gimie to extract repository metadata and converts it to a publiccode object. The
editor then resets the form and populates it with the returned values.

This reuses the editor's existing import pipeline (the same one behind the
"Upload an existing publiccode.yml" flow) and the gimie→publiccode converter from
gimie PR #138 (`gimie/converters/publiccode.py`, currently on the `pr-138` branch of
the `modules/gimie` submodule).

## Goals

- A distinct toolbar button + modal that accepts a GitHub repo URL.
- The form is prefilled from gimie-derived metadata with a single action.
- Reuse, not reinvent: lean on the existing editor import pipeline and the existing
  Python converter.

## Non-goals

- Filling fields gimie cannot derive (`platforms`, `developmentStatus`,
  `softwareType`, etc.) — these remain for the user to complete.
- Merging into a partially-filled form. The chosen behavior is reset-then-fill.
- Private-repo support beyond whatever the gimie-api `GITHUB_TOKEN` already grants.

## Decisions (from brainstorming)

- **UI placement:** Separate "Prefill from GitHub" button + its own modal (not folded
  into the existing Upload modal).
- **Fill behavior:** Reset, then fill — identical to the existing Upload-from-URL flow
  (`resetFormHandler()` then `reset(publicCode)`). User-typed values are discarded.
- **Mapping location:** On gimie-api (Approach A). The endpoint returns a ready
  publiccode JSON object; the frontend importer is a thin `fetch`.

## Architecture

Data flow:

```
[Prefill from GitHub button]
  -> GimiePrefillModal (URL input + loading/error states)
  -> prefillFromGimieHandler({ url })
       resetFormHandler()
       raw = await importFromGimie(new URL(url))
       await processImported(raw)            // existing: publicCodeAdapter + linter + reset(form)
  -> gimie-api  GET /publiccode/{repo}
       Project(url).extract()                // RDF graph
       convert_to_publiccode(graph)          // PR #138 converter -> dict
       JSONResponse(dict)
  -> form populated
```

### Component 1 — gimie-api endpoint

File: `modules/gimie-api/app/main.py`

```
GET /publiccode/{full_path:path}
  Project(full_path).extract()  ->  convert_to_publiccode(graph)  ->  JSONResponse(dict)
```

- Mirrors the existing `/gimie/jsonld` handler's structure and try/except error shape.
- Imports `convert_to_publiccode` from `gimie.converters.publiccode` (PR #138).
- CORS already allows `http://localhost:3000` (the editor's dev port) and
  `http://localhost:4321`; no CORS change required.

### Component 2 — frontend importer

File: `modules/publiccode-editor/src/app/importers/gimie.importer.ts`

```ts
const importFromGimie = async (repoUrl: URL): Promise<PublicCode> => {
  const res = await fetch(`${GIMIE_API_URL}/publiccode/${repoUrl.href}`);
  if (!res.ok) throw new Error(`gimie-api ${res.status}`);
  const pc = await res.json();
  return normalize(pc);
};
```

Normalization performed here (until the upstream PR fixes them):

- `publiccodeYmlVersion`: gimie emits `"0.5"`; the editor expects `"0.5.0"`. Patch it.
- Contact emails: PR #138 corrupts emails (replaces `@` with the character `d` via
  `\x64`). Strip the `email` field from each contact so we never inject invalid data.
  Revisit once the PR is fixed.

### Component 3 — modal

File: `modules/publiccode-editor/src/app/components/GimiePrefillModal.tsx`

A slimmed clone of `UploadModal.tsx` using `design-react-kit` `Modal`:

- Single URL `Input` (placeholder: a sample GitHub repo URL).
- A **Prefill** submit button.
- **Loading** state (gimie calls take several seconds — show a spinner / disabled
  button) and an inline **error** state on failure.

### Component 4 — toolbar button + handler

Files: `modules/publiccode-editor/src/app/components/EditorToolbar.tsx`,
`modules/publiccode-editor/src/app/components/Editor.tsx`

- Add a "Prefill from GitHub" button to the toolbar that opens `GimiePrefillModal`.
- Add `prefillFromGimieHandler({ url })` in `Editor.tsx`:

```
prefillFromGimieHandler({ url }):
  resetFormHandler()
  raw = await importFromGimie(new URL(url))
  await processImported(raw)
```

`processImported` (existing) runs `publicCodeAdapter` + `linter`, so gimie's partial
object (with `null` fields) is sanitized and merged onto `defaultValues` safely before
`reset(form)`.

### Component 5 — config

File: `modules/publiccode-editor/src/app/contents/constants.ts`

- Add `VITE_GIMIE_API_URL: GIMIE_API_URL` to the destructured `import.meta.env`, with a
  default of `http://localhost:45400`.

## Error handling

- **API:** wrap extraction in try/except like `/gimie/jsonld`; on failure return the
  error payload (the frontend treats non-2xx as an import error).
- **Frontend:** `importFromGimie` throws on non-2xx; the handler surfaces it via the
  modal's error state and the existing `notify(...)` error toast. Invalid URL input is
  caught by `new URL(url)`.

## Testing

- **API:** call `/publiccode/https://github.com/sdsc-ordes/gimie` and assert the
  response is a dict containing `name`, `url`, and `legal.license`.
- **Frontend:** Jest test for `importFromGimie` (mock `fetch`): asserts the returned
  shape, the `publiccodeYmlVersion` normalization to `"0.5.0"`, and email stripping.
  Mirrors `importers/gitlab-url-adapter.spec.ts`.

## Known limitations

- Only ~8 fields are derivable (url, name, short/long description, license,
  maintenance type + contacts). The rest stay empty by design.
- gimie extraction takes a few seconds and needs a `GITHUB_TOKEN` (already configured
  in the gimie-api `.env`); public repos only.
- Depends on the `pr-138` branch in the `modules/gimie` submodule providing
  `convert_to_publiccode`. Verified working end-to-end against `sdsc-ordes/gimie`.
