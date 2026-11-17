import { requireNativeView } from 'expo';
import type { ViewProps } from 'react-native';

export type SnackARViewProps = ViewProps & {
  /** 検出した領域の枠を表示する（検証用） */
  debug?: boolean;
};

export const SnackARView = requireNativeView<SnackARViewProps>('SnackAR');
