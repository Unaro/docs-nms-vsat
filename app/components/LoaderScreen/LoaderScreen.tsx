
import styles from './LoaderScreen.module.css'

export const Loader = () => {
    return <div className={styles['loader']} />
}

export default function LoaderScreen() {

    return <div className={styles['main']}>
        <Loader />
    </div>
}