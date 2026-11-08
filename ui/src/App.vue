<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { RouterLink, RouterView, useRoute, useRouter } from 'vue-router'
import ErrorBanner from './components/ErrorBanner.vue'
import { api, loadDirectory, session, signOut } from './session'

const favicon = `${import.meta.env.BASE_URL}favicon.svg`
const route = useRoute()
const router = useRouter()

const loading = ref(false)
const loadError = ref<unknown>(null)

async function load() {
  if (!session.token) return
  loading.value = true
  loadError.value = null
  try {
    session.me ??= await api.value.me()
    await loadDirectory()
  } catch (error) {
    loadError.value = error
  } finally {
    loading.value = false
  }
}
watch(() => session.token, load, { immediate: true })

// The project the sidebar points at: the one in the URL, else the last one opened, else the first.
const lastProjectKey = 'whatfeature.lastProject'
const routeProject = computed(() => route.params.project as string | undefined)
watch(routeProject, (key) => key && localStorage.setItem(lastProjectKey, key), { immediate: true })

const activeProjects = computed(() => session.projects.filter((project) => !project.archivedAt))
const currentProject = computed(() => {
  const key = routeProject.value ?? localStorage.getItem(lastProjectKey)
  return session.projects.find((project) => project.key === key) ?? activeProjects.value[0]
})

function switchProject(key: string) {
  const name = route.params.project && route.name !== 'flag' ? route.name : 'flags'
  void router.push({ name: name ?? 'flags', params: { project: key } })
}

const projectLinks = [
  { name: 'flags', label: 'Flags' },
  { name: 'evaluate', label: 'Try a context' },
  { name: 'tracking', label: 'Tracking' },
]
const isActive = (name: string) => route.name === name || (name === 'flags' && route.name === 'flag')
</script>

<template>
  <RouterView v-if="route.name === 'sign-in'" />
  <div v-else class="shell">
    <aside class="sidebar">
      <RouterLink to="/projects" class="brand">
        <img :src="favicon" alt="" width="22" height="22" />
        WhatFeature
      </RouterLink>

      <div v-if="currentProject" class="section">
        <label class="section-label" for="project-select">Project</label>
        <select id="project-select" :value="currentProject.key" @change="switchProject(($event.target as HTMLSelectElement).value)">
          <option v-for="project in activeProjects" :key="project.id" :value="project.key">{{ project.name }}</option>
          <option v-if="currentProject.archivedAt" :value="currentProject.key">{{ currentProject.name }} (archived)</option>
        </select>
        <nav>
          <RouterLink
            v-for="link in projectLinks"
            :key="link.name"
            :to="{ name: link.name, params: { project: currentProject.key } }"
            :class="{ active: isActive(link.name) }"
          >
            {{ link.label }}
          </RouterLink>
        </nav>
      </div>

      <div class="section">
        <span class="section-label">Server</span>
        <nav>
          <RouterLink to="/projects" :class="{ active: route.name === 'projects' }">Projects</RouterLink>
          <RouterLink to="/tokens" :class="{ active: route.name === 'tokens' }">Tokens</RouterLink>
          <RouterLink to="/audit" :class="{ active: route.name === 'audit' }">Audit log</RouterLink>
        </nav>
      </div>

      <div class="account">
        <div v-if="session.me" class="small">
          <div class="muted">Signed in as</div>
          <div class="token-name" :title="session.me.id">{{ session.me.name }}</div>
        </div>
        <button class="small" @click="signOut()">Sign out</button>
      </div>
    </aside>

    <main class="content">
      <div v-if="loadError" class="page"><ErrorBanner :error="loadError" /></div>
      <div v-else-if="loading && session.projects.length === 0" class="page muted">Loading…</div>
      <RouterView v-else :key="`${route.params.project}/${route.params.flag}`" />
    </main>
  </div>
</template>

<style scoped>
.shell { display: grid; grid-template-columns: 232px 1fr; min-height: 100vh; }
.sidebar {
  position: sticky; top: 0; height: 100vh; overflow-y: auto;
  border-right: 1px solid var(--border); background: var(--panel);
  padding: 16px 12px; display: flex; flex-direction: column; gap: 22px;
}
.brand { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 15px; color: var(--text); padding: 0 6px; }
.brand:hover { text-decoration: none; }
.section { display: flex; flex-direction: column; gap: 6px; }
.section-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); padding: 0 6px; }
.section select { margin: 0 2px 4px; }
nav { display: flex; flex-direction: column; gap: 1px; }
nav a { padding: 6px 8px; border-radius: 6px; color: var(--text); }
nav a:hover { background: var(--panel-2); text-decoration: none; }
nav a.active { background: var(--accent-soft); color: var(--accent); font-weight: 550; }
.account { margin-top: auto; display: flex; flex-direction: column; gap: 8px; padding: 12px 6px 0; border-top: 1px solid var(--border); }
.token-name { font-weight: 550; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.content { min-width: 0; }
@media (max-width: 760px) {
  .shell { grid-template-columns: 1fr; }
  .sidebar { position: static; height: auto; }
}
</style>
