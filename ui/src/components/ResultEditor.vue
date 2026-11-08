<script setup lang="ts">
import { computed } from 'vue'
import type { RuleResult, WeightedVariant } from '../api'
import { evenWeights, percent, totalWeight } from '../model'

// What a rule or the default serves: one variant, or a percentage rollout. Weights are kept out of 10,000, as the
// server stores them; the inputs show percentages with up to two decimals.
const props = defineProps<{ modelValue: RuleResult; variants: string[] }>()
const emit = defineEmits<{ 'update:modelValue': [RuleResult] }>()

const rollout = computed(() => ('rollout' in props.modelValue ? props.modelValue.rollout : null))
const total = computed(() => rollout.value?.reduce((sum, entry) => sum + entry.weight, 0) ?? totalWeight)

function setMode(mode: 'variant' | 'rollout') {
  if (mode === 'variant') {
    emit('update:modelValue', { variant: rollout.value?.[0]?.variant ?? props.variants[0] ?? '' })
  } else if (!rollout.value) {
    const current = 'variant' in props.modelValue ? props.modelValue.variant : props.variants[0]
    const names = [current, ...props.variants.filter((name) => name !== current)].slice(0, 2).filter((name) => name !== undefined)
    const weights = evenWeights(names.length)
    emit('update:modelValue', { rollout: names.map((variant, index) => ({ variant, weight: weights[index] ?? 0 })) })
  }
}

function setRollout(entries: WeightedVariant[]) {
  emit('update:modelValue', { rollout: entries })
}

function setPercent(index: number, text: string) {
  const value = Number(text)
  if (!Number.isFinite(value)) return
  setRollout(rollout.value!.map((entry, i) => (i === index ? { ...entry, weight: Math.round(value * 100) } : entry)))
}

function setVariant(index: number, variant: string) {
  setRollout(rollout.value!.map((entry, i) => (i === index ? { ...entry, variant } : entry)))
}

function addEntry() {
  const used = new Set(rollout.value!.map((entry) => entry.variant))
  const variant = props.variants.find((name) => !used.has(name)) ?? props.variants[0] ?? ''
  setRollout([...rollout.value!, { variant, weight: Math.max(0, totalWeight - total.value) }])
}

function removeEntry(index: number) {
  setRollout(rollout.value!.filter((_, i) => i !== index))
}

function splitEvenly() {
  const weights = evenWeights(rollout.value!.length)
  setRollout(rollout.value!.map((entry, index) => ({ ...entry, weight: weights[index] ?? 0 })))
}
</script>

<template>
  <div class="result">
    <div class="row">
      <select :value="rollout ? 'rollout' : 'variant'" aria-label="Serve" @change="setMode(($event.target as HTMLSelectElement).value as 'variant' | 'rollout')">
        <option value="variant">a variant</option>
        <option value="rollout">a percentage rollout</option>
      </select>
      <select
        v-if="!rollout && 'variant' in modelValue"
        :value="modelValue.variant"
        aria-label="Variant"
        :class="{ invalid: !variants.includes(modelValue.variant) }"
        @change="emit('update:modelValue', { variant: ($event.target as HTMLSelectElement).value })"
      >
        <option v-if="!variants.includes(modelValue.variant)" :value="modelValue.variant">{{ modelValue.variant || '(choose)' }}</option>
        <option v-for="name in variants" :key="name" :value="name">{{ name }}</option>
      </select>
    </div>

    <div v-if="rollout" class="rollout">
      <div class="bar" aria-hidden="true">
        <span
          v-for="(entry, index) in rollout"
          :key="index"
          :style="{ flexGrow: entry.weight, background: `hsl(${(index * 67 + 235) % 360} 65% 60%)` }"
          :title="`${entry.variant} ${percent(entry.weight)}`"
        />
      </div>
      <div v-for="(entry, index) in rollout" :key="index" class="row">
        <span class="swatch" :style="{ background: `hsl(${(index * 67 + 235) % 360} 65% 60%)` }" />
        <select :value="entry.variant" aria-label="Variant" @change="setVariant(index, ($event.target as HTMLSelectElement).value)">
          <option v-if="!variants.includes(entry.variant)" :value="entry.variant">{{ entry.variant }}</option>
          <option v-for="name in variants" :key="name" :value="name">{{ name }}</option>
        </select>
        <input
          type="number"
          class="percent"
          min="0"
          max="100"
          step="0.01"
          :value="entry.weight / 100"
          aria-label="Percent"
          @input="setPercent(index, ($event.target as HTMLInputElement).value)"
        />
        <span class="muted">%</span>
        <button class="ghost icon" :disabled="rollout.length <= 1" aria-label="Remove from rollout" @click="removeEntry(index)">✕</button>
      </div>
      <div class="row">
        <button class="small" @click="addEntry">Add variant</button>
        <button class="small" @click="splitEvenly">Split evenly</button>
        <span v-if="total !== totalWeight" class="pill warn">Adds up to {{ percent(total) }}, not 100%</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.result { display: flex; flex-direction: column; gap: 8px; }
.rollout { display: flex; flex-direction: column; gap: 6px; padding-left: 2px; }
.bar { display: flex; height: 8px; border-radius: 4px; overflow: hidden; background: var(--panel-2); max-width: 420px; }
.bar span { flex-basis: 0; min-width: 0; }
.swatch { width: 10px; height: 10px; border-radius: 3px; flex: none; }
.percent { width: 90px; }
</style>
