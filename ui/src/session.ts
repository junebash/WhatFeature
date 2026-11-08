import { computed, reactive } from 'vue'
import { AdminAPI, type Environment, type Project, type Token } from './api'

// The signed-in admin token, and the projects and environments most pages need. The token is kept in
// sessionStorage (gone when the tab closes), or localStorage when the user asks to be remembered.

const storageKey = 'whatfeature.adminToken'

function storedToken(): string | null {
  return sessionStorage.getItem(storageKey) ?? localStorage.getItem(storageKey)
}

export const session = reactive({
  token: storedToken(),
  me: null as Token | null,
  /** Every project, archived ones included, with its environments (archived included). */
  projects: [] as Project[],
  environments: {} as Record<string, Environment[]>,
})

let onSignOut: () => void = () => {}
export function whenSignedOut(callback: () => void) {
  onSignOut = callback
}

export const api = computed(() => new AdminAPI(session.token ?? '', signOut))

/** Checks the token with `GET /me`, then saves it. Throws the API's error if it doesn't work. */
export async function signIn(token: string, remember: boolean) {
  const me = await new AdminAPI(token).me()
  signOut({ quietly: true })
  ;(remember ? localStorage : sessionStorage).setItem(storageKey, token)
  session.token = token
  session.me = me
}

export function signOut({ quietly = false } = {}) {
  sessionStorage.removeItem(storageKey)
  localStorage.removeItem(storageKey)
  const wasSignedIn = session.token !== null
  session.token = null
  session.me = null
  session.projects = []
  session.environments = {}
  tokensLoaded = null
  if (wasSignedIn && !quietly) onSignOut()
}

/** Reloads every project and environment. Call after changing one. */
export async function loadDirectory() {
  const projects = await api.value.projects(true)
  const environments = await Promise.all(projects.map((project) => api.value.environments(project.key, true)))
  session.projects = projects
  session.environments = Object.fromEntries(projects.map((project, index) => [project.id, environments[index] ?? []]))
}

export function projectByKey(key: string): Project | undefined {
  return session.projects.find((project) => project.key === key)
}

/** A project's environments that aren't archived, in the server's order. */
export function activeEnvironments(projectKey: string): Environment[] {
  const project = projectByKey(projectKey)
  return project ? (session.environments[project.id] ?? []).filter((environment) => !environment.archivedAt) : []
}

/** "demo / prod" for an environment ID, or the ID itself if it's unknown. */
export function environmentLabel(id: string): string {
  for (const project of session.projects) {
    const environment = session.environments[project.id]?.find((environment) => environment.id === id)
    if (environment) return `${project.key} / ${environment.key}`
  }
  return id
}

export function projectLabel(id: string): string {
  return session.projects.find((project) => project.id === id)?.key ?? id
}

/** Token names by ID, for showing who did something. Loaded on first use; `loadTokens()` refreshes. */
const tokenNames = reactive(new Map<string, string>())
let tokensLoaded: Promise<void> | null = null

export function loadTokens(): Promise<void> {
  tokensLoaded = api.value.tokens().then(
    (tokens) => {
      tokenNames.clear()
      for (const token of tokens) tokenNames.set(token.id, token.name)
    },
    () => {
      tokensLoaded = null
    },
  )
  return tokensLoaded
}

/** `token:<id>` as the token's name, `system:seed` as "seed (system)". */
export function actorLabel(actor: string): string {
  if (!tokensLoaded) void loadTokens()
  if (actor.startsWith('token:')) return tokenNames.get(actor.slice(6)) ?? actor
  if (actor.startsWith('system:')) return `${actor.slice(7)} (system)`
  return actor
}
