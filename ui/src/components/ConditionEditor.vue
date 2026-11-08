<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { Condition, JSONValue, Operator } from '../api'
import { operandKind, operatorGroups, withOperator } from '../model'
import ScalarInput from './ScalarInput.vue'

// One condition: attribute, operator, and a value input that fits the operator.
const props = defineProps<{ modelValue: Condition; attributes: string[] }>()
const emit = defineEmits<{ 'update:modelValue': [Condition]; remove: [] }>()

const kind = computed(() => operandKind(props.modelValue.operator))

function update(changes: Partial<Condition>) {
  emit('update:modelValue', { ...props.modelValue, ...changes })
}

// Lists: one item per line, all text or all numbers. Anything else (mixed, objects) is edited as a JSON array.
type ListMode = 'text' | 'number' | 'json'
function listModeOf(value: JSONValue | undefined): ListMode {
  if (!Array.isArray(value) || value.every((item) => typeof item === 'string')) return 'text'
  if (value.every((item) => typeof item === 'number')) return 'number'
  return 'json'
}
function listText(value: JSONValue | undefined, mode: ListMode): string {
  const items = Array.isArray(value) ? value : []
  return mode === 'json' ? JSON.stringify(items) : items.map(String).join('\n')
}

const listMode = ref<ListMode>(listModeOf(props.modelValue.value))
const listInput = ref(listText(props.modelValue.value, listMode.value))
const listProblem = ref<string | null>(null)
watch(
  () => props.modelValue.value,
  (value) => {
    if (kind.value !== 'list' || JSON.stringify(value) === JSON.stringify(parseList(listInput.value, listMode.value))) return
    listMode.value = listModeOf(value)
    listInput.value = listText(value, listMode.value)
  },
)

function parseList(text: string, mode: ListMode): JSONValue[] | undefined {
  try {
    if (mode === 'json') {
      const parsed = JSON.parse(text) as JSONValue
      return Array.isArray(parsed) ? parsed : undefined
    }
    const lines = text.split('\n').map((line) => line.trim()).filter((line) => line !== '')
    if (mode === 'text') return lines
    const numbers = lines.map(Number)
    return numbers.every(Number.isFinite) ? numbers : undefined
  } catch {
    return undefined
  }
}

function commitList() {
  const list = parseList(listInput.value, listMode.value)
  listProblem.value = list ? null : listMode.value === 'json' ? 'Must be a JSON array' : 'Every line must be a number'
  if (list) update({ value: list })
}

function changeListMode(mode: ListMode) {
  const current = parseList(listInput.value, listMode.value) ?? []
  listMode.value = mode
  listInput.value = mode === 'json' ? JSON.stringify(current) : current.map(String).join('\n')
  commitList()
}

const listId = `attributes-${Math.random().toString(36).slice(2)}`
</script>

<template>
  <div class="condition">
    <input
      :value="modelValue.attribute"
      class="attribute"
      placeholder="attribute"
      aria-label="Attribute"
      :list="listId"
      @input="update({ attribute: ($event.target as HTMLInputElement).value })"
    />
    <datalist :id="listId">
      <option v-for="attribute in attributes" :key="attribute" :value="attribute" />
    </datalist>
    <select
      :value="modelValue.operator"
      class="operator"
      aria-label="Operator"
      @change="emit('update:modelValue', withOperator(modelValue, ($event.target as HTMLSelectElement).value as Operator))"
    >
      <optgroup v-for="group in operatorGroups" :key="group.label" :label="group.label">
        <option v-for="op in group.operators" :key="op.value" :value="op.value">{{ op.label }}</option>
      </optgroup>
    </select>

    <div class="value">
      <ScalarInput v-if="kind === 'any'" :model-value="modelValue.value" @update:model-value="update({ value: $event })" />
      <div v-else-if="kind === 'list'" class="stack tight grow">
        <div class="row top">
          <select :value="listMode" aria-label="List item type" @change="changeListMode(($event.target as HTMLSelectElement).value as ListMode)">
            <option value="text">text</option>
            <option value="number">numbers</option>
            <option value="json">JSON array</option>
          </select>
          <textarea
            v-model="listInput"
            class="grow"
            :rows="listMode === 'json' ? 2 : Math.min(6, Math.max(2, listInput.split('\n').length))"
            :placeholder="listMode === 'json' ? '[&quot;a&quot;, 1]' : 'One per line'"
            :class="{ invalid: listProblem }"
            aria-label="Values"
            @input="commitList"
          />
        </div>
        <span v-if="listProblem" class="field-error">{{ listProblem }}</span>
      </div>
      <input
        v-else-if="kind === 'string' || kind === 'version'"
        :value="modelValue.value as string"
        class="grow"
        :placeholder="kind === 'version' ? '2.1.0' : 'text'"
        aria-label="Value"
        @input="update({ value: ($event.target as HTMLInputElement).value })"
      />
      <input
        v-else-if="kind === 'number'"
        type="number"
        step="any"
        class="grow"
        :value="modelValue.value as number"
        aria-label="Value"
        @input="update({ value: Number(($event.target as HTMLInputElement).value) })"
      />
    </div>
    <button class="ghost icon" title="Remove condition" aria-label="Remove condition" @click="emit('remove')">✕</button>
  </div>
</template>

<style scoped>
.condition { display: flex; gap: 6px; align-items: flex-start; flex-wrap: wrap; }
.attribute { width: 150px; }
.operator { width: 140px; }
.value { flex: 1; min-width: 220px; display: flex; }
</style>
