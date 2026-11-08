<script setup lang="ts">
import { computed, ref } from 'vue'
import { RouterLink } from 'vue-router'
import { useAction } from '../action'
import type { Environment, Project } from '../api'
import ErrorBanner from '../components/ErrorBanner.vue'
import Modal from '../components/Modal.vue'
import { fullDate } from '../format'
import { api, loadDirectory, session } from '../session'

const showArchived = ref(false)
const projects = computed(() => session.projects.filter((project) => showArchived.value || !project.archivedAt))
const environmentsOf = (project: Project) =>
  (session.environments[project.id] ?? []).filter((environment) => showArchived.value || !environment.archivedAt)

// One dialog for creating or renaming a project or an environment.
type Editing =
  | { kind: 'project'; project?: Project }
  | { kind: 'environment'; project: Project; environment?: Environment }
const editing = ref<Editing | null>(null)
const keyInput = ref('')
const nameInput = ref('')
const dialog = useAction()
const rowAction = useAction()

function open(target: Editing) {
  editing.value = target
  const existing = target.kind === 'project' ? target.project : target.environment
  keyInput.value = existing?.key ?? ''
  nameInput.value = existing?.name ?? ''
  dialog.error.value = null
}

const dialogTitle = computed(() => {
  const target = editing.value
  if (!target) return ''
  if (target.kind === 'project') return target.project ? `Rename ${target.project.key}` : 'New project'
  return target.environment ? `Rename ${target.environment.key}` : `New environment in ${target.project.key}`
})

async function save() {
  const target = editing.value
  if (!target) return
  const key = keyInput.value.trim()
  const name = nameInput.value.trim()
  const done = await dialog.run(async () => {
    if (target.kind === 'project') {
      if (target.project) {
        await api.value.updateProject(target.project.key, changes(target.project, key, name))
      } else {
        await api.value.createProject(key, name)
      }
    } else if (target.environment) {
      await api.value.updateEnvironment(target.project.key, target.environment.key, changes(target.environment, key, name))
    } else {
      await api.value.createEnvironment(target.project.key, key, name)
    }
    await loadDirectory()
    return true
  })
  if (done) editing.value = null
}

function changes(existing: { key: string; name: string }, key: string, typedName: string) {
  const name = typedName || key
  return { key: key !== existing.key ? key : undefined, name: name !== existing.name ? name : undefined }
}

async function setProjectArchived(project: Project, archived: boolean) {
  if (archived && !confirm(`Archive ${project.key}? Its evaluation tokens stop working, so apps fall back to their code defaults. Unarchiving brings it all back.`)) return
  await rowAction.run(async () => {
    await api.value.setProjectArchived(project.key, archived)
    await loadDirectory()
  })
}

async function setEnvironmentArchived(project: Project, environment: Environment, archived: boolean) {
  if (archived && !confirm(`Archive ${project.key} / ${environment.key}? Its evaluation tokens stop working, so apps fall back to their code defaults. Unarchiving brings it all back.`)) return
  await rowAction.run(async () => {
    await api.value.setEnvironmentArchived(project.key, environment.key, archived)
    await loadDirectory()
  })
}
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Projects &amp; environments</h1>
        <p class="subtitle">Renamed and archived, never deleted. Apps don't notice a new key: evaluation tokens point at environment IDs.</p>
      </div>
      <div class="row">
        <label class="check small"><input v-model="showArchived" type="checkbox" /> Show archived</label>
        <button class="primary" @click="open({ kind: 'project' })">New project</button>
      </div>
    </div>

    <ErrorBanner :error="rowAction.error.value" />

    <div v-if="projects.length === 0" class="card empty">No projects yet. Create one to get started.</div>

    <div v-for="project in projects" :key="project.id" class="card">
      <div class="card-header">
        <div class="row">
          <h2>
            <RouterLink :to="{ name: 'flags', params: { project: project.key } }">{{ project.name }}</RouterLink>
          </h2>
          <code class="muted">{{ project.key }}</code>
          <span v-if="project.archivedAt" class="pill warn">archived</span>
        </div>
        <div class="row">
          <button class="small" @click="open({ kind: 'environment', project })">Add environment</button>
          <button class="small" @click="open({ kind: 'project', project })">Rename</button>
          <button v-if="project.archivedAt" class="small" :disabled="rowAction.busy.value" @click="setProjectArchived(project, false)">Unarchive</button>
          <button v-else class="small danger" :disabled="rowAction.busy.value" @click="setProjectArchived(project, true)">Archive</button>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Environment</th>
              <th>Key</th>
              <th>Tracking</th>
              <th>Version</th>
              <th>Created</th>
              <th />
            </tr>
          </thead>
          <tbody>
            <tr v-for="environment in environmentsOf(project)" :key="environment.id">
              <td>
                {{ environment.name }}
                <span v-if="environment.archivedAt" class="pill warn">archived</span>
              </td>
              <td><code>{{ environment.key }}</code></td>
              <td>
                <RouterLink :to="{ name: 'tracking', params: { project: project.key }, query: { env: environment.key } }">
                  <span v-if="environment.tracking.enabled" class="pill on"><span class="dot" /> on</span>
                  <span v-else class="pill off">off</span>
                </RouterLink>
              </td>
              <td class="muted">{{ environment.version }}</td>
              <td class="muted nowrap" :title="fullDate(environment.createdAt)">{{ new Date(environment.createdAt).toLocaleDateString() }}</td>
              <td>
                <div class="row" style="justify-content: flex-end">
                  <button class="small ghost" @click="open({ kind: 'environment', project, environment })">Rename</button>
                  <button v-if="environment.archivedAt" class="small ghost" :disabled="rowAction.busy.value" @click="setEnvironmentArchived(project, environment, false)">Unarchive</button>
                  <button v-else class="small ghost danger" :disabled="rowAction.busy.value" @click="setEnvironmentArchived(project, environment, true)">Archive</button>
                </div>
              </td>
            </tr>
            <tr v-if="environmentsOf(project).length === 0">
              <td colspan="6" class="muted">No environments.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <Modal v-if="editing" :title="dialogTitle" @close="editing = null">
      <form id="name-form" class="stack" @submit.prevent="save">
        <label class="field">
          Key
          <input v-model="keyInput" required placeholder="my-app" autofocus />
          <span class="hint">Used in URLs and the CLI. Letters, numbers, <code>.</code> <code>_</code> <code>-</code>.</span>
        </label>
        <label class="field">
          Display name
          <input v-model="nameInput" :placeholder="keyInput || 'Defaults to the key'" />
        </label>
        <ErrorBanner :error="dialog.error.value" />
      </form>
      <template #footer>
        <button @click="editing = null">Cancel</button>
        <button class="primary" type="submit" form="name-form" :disabled="dialog.busy.value || !keyInput.trim()">Save</button>
      </template>
    </Modal>
  </div>
</template>
