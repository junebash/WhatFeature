<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import { flagTypes, type FlagDetail, type FlagType, type JSONValue } from '../api'
import ErrorBanner from '../components/ErrorBanner.vue'
import Modal from '../components/Modal.vue'
import VariantValueInput from '../components/VariantValueInput.vue'
import { timeAgo, fullDate } from '../format'
import { defaultVariants, describeConfig, emptyVariantValue } from '../model'
import { activeEnvironments, api, projectByKey } from '../session'

const route = useRoute()
const router = useRouter()
const projectKey = route.params.project as string
const project = computed(() => projectByKey(projectKey))
const environments = computed(() => activeEnvironments(projectKey))

const details = ref<FlagDetail[]>([])
const showArchived = ref(false)
const search = ref('')
const load = useAction()

// The list endpoint has no configs, so each flag's detail is fetched too: one call per flag, in parallel.
async function refresh() {
  await load.run(async () => {
    const flags = await api.value.flags(projectKey, true)
    details.value = await Promise.all(flags.map((flag) => api.value.flag(projectKey, flag.key)))
  })
}
onMounted(refresh)

const visible = computed(() => {
  const query = search.value.trim().toLowerCase()
  return details.value.filter(
    ({ flag }) =>
      (showArchived.value || !flag.archivedAt) &&
      (!query || flag.key.toLowerCase().includes(query) || flag.description.toLowerCase().includes(query)),
  )
})
const archivedCount = computed(() => details.value.filter(({ flag }) => flag.archivedAt).length)

// Quick kill switch from the list: flips `enabled`, keeping the rules.
const toggle = useAction()
async function setEnabled(detail: FlagDetail, environment: string, enabled: boolean) {
  const config = detail.configs[environment]
  if (!config) return
  await toggle.run(async () => {
    const saved = await api.value.setConfig(projectKey, environment, detail.flag.key, {
      enabled,
      rules: config.rules,
      defaultResult: config.defaultResult,
    })
    detail.configs[environment] = saved
  })
}

// New flag
const creating = ref(false)
const create = useAction()
const newKey = ref('')
const newType = ref<FlagType>('boolean')
const newDescription = ref('')
const newExperiment = ref(false)
const newVariants = ref<{ name: string; value: JSONValue }[]>([])
const newDefault = ref('')

function openCreate() {
  creating.value = true
  newKey.value = ''
  newDescription.value = ''
  newExperiment.value = false
  setType('boolean')
  create.error.value = null
}

function setType(type: FlagType) {
  newType.value = type
  newVariants.value = defaultVariants(type).map(([name, value]) => ({ name, value }))
  newDefault.value = type === 'boolean' ? 'off' : (newVariants.value[0]?.name ?? '')
}

async function submitCreate() {
  const variants = Object.fromEntries(newVariants.value.map((variant) => [variant.name.trim(), variant.value]))
  const detail = await create.run(() =>
    api.value.createFlag(projectKey, {
      key: newKey.value.trim(),
      type: newType.value,
      variants,
      description: newDescription.value.trim() || undefined,
      isExperiment: newExperiment.value || undefined,
      defaultVariant: newDefault.value || undefined,
    }),
  )
  if (detail) {
    creating.value = false
    await router.push({ name: 'flag', params: { project: projectKey, flag: detail.flag.key } })
  }
}

const variantNames = computed(() => newVariants.value.map((variant) => variant.name.trim()).filter(Boolean))
const duplicateNames = computed(() => variantNames.value.length !== new Set(variantNames.value).size)
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Flags <span v-if="project" class="muted">· {{ project.name }}</span></h1>
        <p class="subtitle">Each flag has its own config in every environment. New flags start disabled everywhere.</p>
      </div>
      <button class="primary" @click="openCreate">New flag</button>
    </div>

    <div class="row">
      <input v-model="search" type="search" placeholder="Search flags" class="grow" style="max-width: 320px" aria-label="Search flags" />
      <label v-if="archivedCount" class="check small"><input v-model="showArchived" type="checkbox" /> Show archived ({{ archivedCount }})</label>
    </div>

    <ErrorBanner :error="load.error.value ?? toggle.error.value" />

    <div class="card">
      <div v-if="load.busy.value && details.length === 0" class="empty">Loading…</div>
      <div v-else-if="visible.length === 0" class="empty">
        {{ details.length === 0 ? 'No flags yet.' : 'No flags match.' }}
      </div>
      <div v-else class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Flag</th>
              <th v-for="environment in environments" :key="environment.id">{{ environment.key }}</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="detail in visible" :key="detail.flag.key">
              <td class="flag-cell">
                <div class="row">
                  <RouterLink :to="{ name: 'flag', params: { project: projectKey, flag: detail.flag.key } }" class="flag-key">
                    {{ detail.flag.key }}
                  </RouterLink>
                  <span class="pill">{{ detail.flag.type }}</span>
                  <span v-if="detail.flag.isExperiment" class="pill accent">experiment</span>
                  <span v-if="detail.flag.archivedAt" class="pill warn">archived</span>
                </div>
                <p v-if="detail.flag.description" class="muted small">{{ detail.flag.description }}</p>
              </td>
              <td v-for="environment in environments" :key="environment.id" class="env-cell">
                <div v-if="detail.configs[environment.key]" class="row">
                  <input
                    type="checkbox"
                    class="switch"
                    :checked="detail.configs[environment.key]!.enabled"
                    :disabled="toggle.busy.value || !!detail.flag.archivedAt"
                    :aria-label="`${detail.flag.key} in ${environment.key}`"
                    @change="setEnabled(detail, environment.key, ($event.target as HTMLInputElement).checked)"
                  />
                  <span class="small" :class="{ muted: !detail.configs[environment.key]!.enabled }">
                    {{ describeConfig(detail.configs[environment.key]!) }}
                  </span>
                </div>
              </td>
              <td class="muted small nowrap" :title="fullDate(detail.flag.createdAt)">{{ timeAgo(detail.flag.createdAt) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <Modal v-if="creating" title="New flag" @close="creating = false">
      <form id="create-flag" class="stack" @submit.prevent="submitCreate">
        <label class="field">
          Key
          <input v-model="newKey" required placeholder="new-onboarding" autofocus />
          <span class="hint">Can't change later. Letters, numbers, <code>.</code> <code>_</code> <code>-</code>.</span>
        </label>
        <label class="field">
          Type
          <select :value="newType" @change="setType(($event.target as HTMLSelectElement).value as FlagType)">
            <option v-for="type in flagTypes" :key="type" :value="type">{{ type }}</option>
          </select>
          <span class="hint">Can't change later either.</span>
        </label>
        <div class="field">
          <span>Variants</span>
          <div v-for="(variant, index) in newVariants" :key="index" class="row top">
            <input v-model="variant.name" placeholder="name" style="width: 130px" aria-label="Variant name" />
            <VariantValueInput v-model="variant.value" :type="newType" class="grow" />
            <button type="button" class="ghost icon" :disabled="newVariants.length <= 1" aria-label="Remove variant" @click="newVariants.splice(index, 1)">✕</button>
          </div>
          <div>
            <button type="button" class="small" @click="newVariants.push({ name: '', value: emptyVariantValue(newType) })">Add variant</button>
          </div>
          <span v-if="duplicateNames" class="field-error">Variant names must be different.</span>
        </div>
        <label class="field">
          Serves, once enabled
          <select v-model="newDefault">
            <option v-for="name in variantNames" :key="name" :value="name">{{ name }}</option>
          </select>
        </label>
        <label class="field">
          Description
          <input v-model="newDescription" placeholder="What it's for" />
        </label>
        <label class="check"><input v-model="newExperiment" type="checkbox" /> A/B test (marks results with <code>experiment: true</code>)</label>
        <ErrorBanner :error="create.error.value" />
      </form>
      <template #footer>
        <button @click="creating = false">Cancel</button>
        <button class="primary" type="submit" form="create-flag" :disabled="create.busy.value || !newKey.trim() || duplicateNames || variantNames.length === 0">
          Create
        </button>
      </template>
    </Modal>
  </div>
</template>

<style scoped>
.flag-cell { min-width: 240px; }
.flag-key { font-family: var(--mono); font-weight: 600; font-size: 13px; }
.env-cell { min-width: 150px; }
</style>
