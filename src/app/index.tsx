import { StyleSheet } from 'react-native';

import { SnackARView } from '../../modules/snack-ar';

/** 起動したらすぐカメラ＋ARが始まる。画面はこれだけ */
export default function ARScreen() {
  return <SnackARView style={StyleSheet.absoluteFill} debug={__DEV__} />;
}
