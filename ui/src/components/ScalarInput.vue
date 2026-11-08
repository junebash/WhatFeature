<script setup lang="ts">
import { ref, watch } from 'vue'
import type { JSONValue } from '../api'
import { formatScalar, parseScalar, scalarType, type ScalarType } from '../model'

// One JSON value typed as text, a number, true/false or raw JSON, with a type picker. Emits only values that
// parse; while the text doesn't, it shows why.
const props = defineProps<{ modelValue: JSONValue | undefined; placeholder?: string }>()
const emit = defineEmits<{ 'update:modelValue': [JSONValue] }>()

const type = ref<ScalarType>(scalarType(props.modelValue))
const text = ref(formatScalar(props.modelValue, type.value))
const problem = ref<string | null>(null)

watch(
  () => props.modelValue,
  (value) => {
    // Leave half-typed text alone when the value it already stands for comes back.
    if (problem.value === null && safeParse(text.value, type.value) === JSON.stringify(value)) return
    type.value = scalarType(value)
    text.value = formatScalar(value, type.value)
    problem.value = null
  },
)

function safeParse(input: string, as: ScalarType): string | undefined {
  try {
    return JSON.stringify(parseScalar(input, as))
  } catch {
    return undefined
  }
}

function commit() {
  try {
    const value = parseScalar(text.value, type.value)
    problem.value = null
    emit('update:modelValue', value)
  } catch (error) {
    problem.value = (error as Error).message
  }
}

function changeType(next: ScalarType) {
  type.value = next
  if (next === 'boolean' && text.value !== 'true' && text.value !== 'false') text.value = 'true'
  commit()
}
</script>

<template>
  <div class="scalar">
    <select :value="type" aria-label="Value type" @change="changeType(($event.target as HTMLSelectElement).value as ScalarType)">
      <option value="text">text</option>
      <option value="number">number</option>
      <option value="boolean">true/false</option>
      <option value="json">JSON</option>
    </select>
    <select v-if="type === 'boolean'" v-model="text" aria-label="Value" @change="commit">
      <option value="true">true</option>
      <option value="false">false</option>
    </select>
    <input
      v-else
      v-model="text"
      class="grow"
      :class="{ invalid: problem }"
      :inputmode="type === 'number' ? 'decimal' : undefined"
      :placeholder="placeholder ?? 'value'"
      :title="problem ?? undefined"
      aria-label="Value"
      @input="commit"
    />
  </div>
</template>

<style scoped>
.scalar { display: flex; gap: 4px; min-width: 0; flex: 1; }
.scalar select:first-child { width: 96px; flex: none; }
</style>
